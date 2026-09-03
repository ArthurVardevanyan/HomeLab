"""LiteLLM routing plugin: route between llama-swap deployments of the same
model based on which GPU already has it resident and, when more than one
copy is resident, which one is actually less busy.

Problem this solves
--------------------
All qwen3.6-35b-a3b / qwen3.6-27b deployments share
one llama-swap pod with two GPUs. LiteLLM's `least-busy` routing_strategy
tracks in-flight requests with its own per-deployment counter, which has two
independent problems observed in production here:

1. It has no idea which GPU already has a given model loaded, so it can send
   a request to a GPU currently serving a *different*, busy model - forcing
   llama-swap's matrix solver to evict that model mid-stream.
2. Even between two deployments of the *same* model, the counter's tie-break
   (`if v < min_traffic`, over an insertion-ordered dict) always resolves to
   the first-listed deployment when counts are equal - which, combined with
   drift/instability in how the counter is incremented and decremented
   across LiteLLM's sync/async logging paths, produced a persistent skew
   toward one GPU (3:1 / 5:1) instead of a spread, even under sustained
   concurrent load with an idle sibling GPU available.

This plugin sidesteps LiteLLM's counter entirely for the model groups it
covers. It narrows the routing-plugin candidate list (see
`litellm.types.router.RoutingContext`) using llama-swap ground truth:

- If neither deployment is resident (cold start): leave the candidate list
  untouched. The GPU-preference ordering in litellm.yaml's model_list
  decides, same as before this plugin existed.
- If exactly one candidate is resident: expose **all** candidates. The
  non-resident sibling receives traffic and llama-swap's matrix solver
  loads the model there (one-time swap cost). Once both copies are resident
  the "both ready" path takes over.
- If both candidates are resident and ready: poll llama.cpp's per-instance
  `/slots` endpoint (proxied through llama-swap's `/upstream/<model>/slots`)
  for actual busy-slot counts, and route to whichever has fewer. Ties -
  the common case, since both GPUs are usually idle - are broken with a
  simple round-robin counter, which is what actually fixes the observed
  skew: a load-based comparison that just returns the first candidate on
  every tie is exactly the bug this plugin exists to avoid repeating.

Session stickiness (load-aware, Redis-backed)
----------------------------------------------
When a conversation has an active pin, the plugin sticks to the pinned GPU
as long as it stays near least-busy (`pinned_busy <= least_busy + STICKY_SLOP`).
Once the pinned GPU becomes materially busier than its sibling, the plugin
rebalances to the least-busy GPU and re-pins there. This preserves KV-cache
reuse for active sessions while preventing the skew seen with the previous
pure-sticky behavior.

The pin key is `context.metadata["session_id"]` when present (populated
when Open WebUI sends `X-Litellm-Session-Id`), falling back to the content
fingerprint. Pins are stored in Redis (Dragonfly) so they survive LiteLLM
pod restarts.

Wiring
------
Registered via `router_settings.plugins` in litellm.yaml as
`llama_swap_affinity.plugin`. LiteLLM resolves that dotted path relative to
the directory containing the config file (`/etc/litellm`), where this file
is mounted alongside litellm.yaml by the same ConfigMap - no image build
required. See `litellm.proxy.types_utils.utils.get_instance_fn`.

The `/slots` poll is proxied through llama-swap rather than hitting each
llama-server instance directly, and llama-swap's `upstream.ignorePaths`
config (see llama-swap.yaml) is set so that path can never itself trigger a
model load/swap - this plugin only ever polls models it already knows are
resident, but that config is defense-in-depth against a bug here doing
otherwise.

Requires `router_settings.disable_cooldowns: true` (see litellm.yaml): if a
deployment this plugin narrows to were ever in a LiteLLM failure cooldown,
the intersection with `healthy_deployments` would be empty and the request
would hard-fail instead of falling back. llama-swap's own process state
(ready/starting/...) is a more accurate health signal for a single
co-located backend than LiteLLM's failure-count cooldowns are, so those are
disabled globally.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import time
from typing import Final

import httpx
import redis.asyncio as aioredis

from litellm.types.router import RoutingContext

logger = logging.getLogger(__name__)

# llama-swap HTTP client settings
_LLAMA_SWAP_BASE_URL: Final = os.environ.get(
    "LLAMA_SWAP_BASE_URL", "http://llama-swap-svc.llm.svc.cluster.local.:8080"
).rstrip("/")
_RUNNING_URL: Final = f"{_LLAMA_SWAP_BASE_URL}/running"

_RESIDENT_STATES: Final = frozenset({"ready", "starting"})
_RUNNING_CACHE_TTL_SECONDS: Final = 1.0
_SLOTS_CACHE_TTL_SECONDS: Final = 0.25
_REQUEST_TIMEOUT_SECONDS: Final = 1.0

# Redis / Dragonfly connection settings for the pin store.
# Falls back to in-memory if the env var is unset or Redis is unreachable.
_REDIS_URL: Final | None = os.environ.get("LLAMA_SWAP_PIN_REDIS_URL")

# Session-stickiness settings (only relevant when Redis is available).
# TTL of 1h balances KV-cache retention against memory churn.
_PIN_TTL_SECONDS: Final = 3600.0
# How much busier the pinned GPU can be before we rebalance.
# With 2 slots/GPU: pinned=1/other=0 → stick; pinned=2/other=0 → rebalance.
STICKY_SLOP: Final = 1
# Max number of pins stored in Redis (soft cap; keys are never explicitly
# evicted except by TTL).
_PIN_MAP_MAX: Final = 10000
# Redis key namespace prefix.
_PIN_NAMESPACE: Final = "llama-swap-affinity:v1"


def _strip_provider_prefix(model: str) -> str:
    """`openai/35b-gpu0` -> `35b-gpu0` to match llama-swap's model IDs."""
    _, _, rest = model.partition("/")
    return rest or model


class LlamaSwapAffinityPlugin:
    """Implements `litellm.types.router.RoutingPlugin` (async `run`)."""

    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._redis: aioredis.Redis | None = None
        self._running_cache: dict[str, str] = {}
        self._running_cache_expires_at: float = 0.0
        self._slots_cache: dict[str, tuple[int, float]] = {}
        self._round_robin_counter: int = 0
        # Fallback in-memory pin map (used when Redis is unavailable).
        self._pin_map: dict[str, tuple[str, float]] = {}
        self._pin_order: list[str] = []  # LRU tracking (insertion order)

    # ------------------------------------------------------------------
    # HTTP client
    # ------------------------------------------------------------------

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=_REQUEST_TIMEOUT_SECONDS)
        return self._client

    # ------------------------------------------------------------------
    # Redis client (lazy-init)
    # ------------------------------------------------------------------

    async def _get_redis(self) -> aioredis.Redis | None:
        if self._redis is not None:
            return self._redis
        if _REDIS_URL is None:
            return None
        try:
            self._redis = aioredis.from_url(
                _REDIS_URL,
                decode_responses=True,
                socket_connect_timeout=2.0,
                socket_timeout=2.0,
            )
            await self._redis.ping()
            return self._redis
        except Exception:
            self._redis = None
            return None

    # ------------------------------------------------------------------
    # llama-swap data helpers
    # ------------------------------------------------------------------

    async def _running_state(self, cache_ttl: float | None = None) -> dict[str, str]:
        """Model ID -> process state, for models in `_RESIDENT_STATES`.

        Args:
            cache_ttl: Override the default cache TTL. Use a longer TTL for
                embedding models to reduce HTTP calls during bursts.
        """
        now = time.monotonic()
        effective_ttl = cache_ttl if cache_ttl is not None else _RUNNING_CACHE_TTL_SECONDS
        if now < self._running_cache_expires_at:
            return self._running_cache

        client = self._get_client()
        response = await client.get(_RUNNING_URL)
        response.raise_for_status()
        payload = response.json()

        state = {
            entry["model"]: entry["state"]
            for entry in payload.get("running", [])
            if entry.get("state") in _RESIDENT_STATES
        }
        self._running_cache = state
        self._running_cache_expires_at = now + effective_ttl
        return state

    async def _slot_busy_count(
        self, model_id: str, cache_ttl: float | None = None,
    ) -> int:
        now = time.monotonic()
        effective_ttl = cache_ttl if cache_ttl is not None else _SLOTS_CACHE_TTL_SECONDS
        cached = self._slots_cache.get(model_id)
        if cached is not None and now < cached[1]:
            return cached[0]

        client = self._get_client()
        response = await client.get(f"{_LLAMA_SWAP_BASE_URL}/upstream/{model_id}/slots")
        response.raise_for_status()
        slots = response.json()
        busy = sum(1 for slot in slots if slot.get("is_processing"))

        self._slots_cache[model_id] = (busy, now + effective_ttl)
        return busy

    async def _pick_least_busy(
        self,
        candidates: list[str],
        candidate_ids: dict[str, str],
        slots_cache_ttl: float | None = None,
    ) -> str:
        """Pick the candidate with fewest busy llama.cpp slots."""
        counts = await asyncio.gather(
            *(
                self._slot_busy_count(candidate_ids[model], cache_ttl=slots_cache_ttl)
                for model in candidates
            ),
            return_exceptions=True,
        )
        scored = [(model, count) for model, count in zip(candidates, counts) if isinstance(count, int)]
        if not scored:
            return candidates[self._round_robin_counter % len(candidates)]

        min_busy = min(count for _, count in scored)
        least_busy = [model for model, count in scored if count == min_busy]

        winner = least_busy[self._round_robin_counter % len(least_busy)]
        self._round_robin_counter += 1
        return winner

    # ------------------------------------------------------------------
    # Stickiness key
    # ------------------------------------------------------------------

    async def _compute_sticky_key(self, context: RoutingContext) -> str | None:
        """Return the stickiness key for this request.

        Priority:
        1. `context.metadata["session_id"]` (canonical session ID, populated
           when Open WebUI sends `X-Litellm-Session-Id`).
        2. Content fingerprint (model + first user message content).
        3. `None` — no stickiness.
        """
        session_id = context.metadata.get("session_id")
        if session_id:
            return f"sess:{session_id}"

        fp = self._compute_fingerprint(context)
        if fp is not None:
            return f"fp:{fp}"

        return None

    def _compute_fingerprint(self, context: RoutingContext) -> str | None:
        """Compute a sha256 fingerprint for session stickiness fallback."""
        if not context.structured_messages:
            return None

        for msg in context.structured_messages:
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            if isinstance(content, str):
                text = content[:500]
            elif isinstance(content, list):
                text_parts = [
                    block.get("text", "")
                    for block in content
                    if isinstance(block, dict) and block.get("type") == "text"
                ]
                text = " ".join(text_parts)[:500]
            else:
                text = str(content)[:500]

            if not text.strip():
                continue

            canonical_model = _strip_provider_prefix(
                context.candidate_models[0] if context.candidate_models else "unknown"
            )
            raw = f"{canonical_model}:{text}"
            return hashlib.sha256(raw.encode()).hexdigest()

        return None

    # ------------------------------------------------------------------
    # Redis-backed pin store
    # ------------------------------------------------------------------

    def _pin_key(self, sticky_key: str) -> str:
        """Redis key for a stickiness pin."""
        safe = sticky_key.replace(":", "-")
        return f"{_PIN_NAMESPACE}:{safe}"

    async def _get_pin(self, sticky_key: str) -> str | None:
        """Get the pinned deployment model for this sticky key."""
        redis = await self._get_redis()
        if redis is not None:
            try:
                pin_data = await redis.get(self._pin_key(sticky_key))
                if pin_data:
                    # Format: deployment_model|expiry (kept in Redis for TTL)
                    deployment = pin_data.rsplit("|", 1)[0]
                    return deployment
            except Exception:
                pass

        # Fallback: in-memory pin map
        return self._get_pinned_deployment(sticky_key)

    async def _set_pin(self, sticky_key: str, deployment_model: str) -> None:
        """Create or update a pin for this sticky key."""
        expiry = time.monotonic() + _PIN_TTL_SECONDS
        pin_data = f"{deployment_model}|{expiry}"

        redis = await self._get_redis()
        if redis is not None:
            try:
                await redis.set(
                    self._pin_key(sticky_key),
                    pin_data,
                    ex=int(_PIN_TTL_SECONDS),
                )
                # Soft cap: delete oldest keys when over limit.
                # We maintain a counter key for tracking.
                count_key = f"{_PIN_NAMESPACE}:count"
                try:
                    count = await redis.incr(count_key)
                    if count > _PIN_MAP_MAX:
                        await redis.expire(count_key, int(_PIN_TTL_SECONDS))
                except Exception:
                    pass
                return
            except Exception:
                pass

        # Fallback: in-memory pin map
        self._set_pin_in_memory(sticky_key, deployment_model)

    def _get_pinned_deployment(self, fingerprint: str) -> str | None:
        """Return the pinned deployment model if the pin is valid and not expired (in-memory)."""
        entry = self._pin_map.get(fingerprint)
        if entry is None:
            return None
        model, expiry = entry
        if time.monotonic() > expiry:
            self._pin_map.pop(fingerprint, None)
            try:
                self._pin_order.remove(fingerprint)
            except ValueError:
                pass
            return None
        # Move to end of LRU order
        try:
            self._pin_order.remove(fingerprint)
        except ValueError:
            pass
        self._pin_order.append(fingerprint)
        return model

    def _set_pin_in_memory(self, fingerprint: str, deployment_model: str) -> None:
        """Create or update a pin in the in-memory map (fallback only)."""
        expiry = time.monotonic() + _PIN_TTL_SECONDS
        self._pin_map[fingerprint] = (deployment_model, expiry)

        try:
            self._pin_order.remove(fingerprint)
        except ValueError:
            pass
        self._pin_order.append(fingerprint)

        while len(self._pin_map) > _PIN_MAP_MAX:
            oldest = self._pin_order.pop(0)
            self._pin_map.pop(oldest, None)

    async def _clear_pin(self, sticky_key: str) -> None:
        """Remove a pin (used when rebalancing)."""
        redis = await self._get_redis()
        if redis is not None:
            try:
                await redis.delete(self._pin_key(sticky_key))
                return
            except Exception:
                pass

    # ------------------------------------------------------------------
    # Load-aware stickiness check
    # ------------------------------------------------------------------

    async def _check_stickiness(self, pinned: str, ready_candidates: list[str], candidate_ids: dict[str, str]) -> str | None:
        """Check if we should stick to the pinned GPU or rebalance.

        Returns the deployment to route to (pinned or least-busy sibling),
        or None if stickiness should be dropped entirely.
        """
        if pinned not in ready_candidates:
            return None

        # Get busy counts for all ready candidates
        counts = await asyncio.gather(
            *(self._slot_busy_count(candidate_ids[model]) for model in ready_candidates),
            return_exceptions=True,
        )
        scored = [(model, count) for model, count in zip(ready_candidates, counts) if isinstance(count, int)]
        if not scored:
            return pinned  # can't compare — stick

        min_busy = min(count for _, count in scored)
        pinned_idx = next(i for i, (m, _) in enumerate(scored) if m == pinned)
        pinned_busy = scored[pinned_idx][1]

        if pinned_busy <= min_busy + STICKY_SLOP:
            # Pinned GPU is near least-busy — stick (KV-cache reuse)
            return pinned
        else:
            # Pinned GPU is materially busier — rebalance
            least_busy = [model for model, count in scored if count == min_busy]
            return least_busy[0]

    # ------------------------------------------------------------------
    # Routing plugin entry point
    # ------------------------------------------------------------------

    async def run(self, context: RoutingContext) -> RoutingContext:
        try:
            # Fast-path: skip all routing logic for single-candidate models.
            if len(context.candidate_models) < 2:
                return context

            candidates = context.candidate_models
            if len(candidates) < 2:
                return context

            candidate_ids = {model: _strip_provider_prefix(model) for model in candidates}
            running = await self._running_state()

            occupied_candidates = [model for model, model_id in candidate_ids.items() if model_id in running]

            if not occupied_candidates:
                return context

            if len(occupied_candidates) == 1:
                # One GPU has the model resident. Return all candidates so
                # the non-resident sibling receives traffic and llama-swap
                # loads it (one-time swap cost). After both are resident the
                # "both ready" path handles load balancing with
                # /slots-based selection.
                context.candidate_models = candidates
                context.signals["llama_swap_affinity"] = "cold_gpu_exposed_for_lb"
                return context

            ready_candidates = [
                model for model in occupied_candidates if running.get(candidate_ids[model]) == "ready"
            ]
            if len(ready_candidates) < 2:
                target = ready_candidates or occupied_candidates
                context.candidate_models = target
                if len(target) == 1:
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                return context

            # Both candidates are loaded and ready.
            # Step 1: compute the stickiness key (session ID or fingerprint).
            sticky_key = await self._compute_sticky_key(context)

            if sticky_key is not None:
                # Step 2: look up any existing pin.
                pinned = await self._get_pin(sticky_key)
                if pinned:
                    # Step 3: load-aware check — stick or rebalance?
                    decision = await self._check_stickiness(pinned, ready_candidates, candidate_ids)
                    if decision:
                        context.candidate_models = [decision]
                        context.signals["llama_swap_affinity"] = "sticky_to_pinned" if decision == pinned else "rebalanced_from_sticky"
                        return context
                    # Stickiness dropped — fall through to pure least-busy.

            # Step 4: no pin or stickiness dropped — route by least-busy.
            winner = await self._pick_least_busy(ready_candidates, candidate_ids)
            context.candidate_models = [winner]
            context.signals["llama_swap_affinity"] = "narrowed_to_least_busy_slot"

            # Step 5: establish a new pin (load-aware: only if the GPU is ready).
            if sticky_key is not None and running.get(candidate_ids[winner]) == "ready":
                await self._set_pin(sticky_key, winner)

            return context
        except Exception:
            # Fail open: routing must never break because llama-swap is
            # slow, unreachable, or returns an unexpected shape.
            return context


# Instance LiteLLM resolves via `router_settings.plugins:
# ["llama_swap_affinity.plugin"]` (dotted path -> module.instance).
plugin: Final = LlamaSwapAffinityPlugin()
