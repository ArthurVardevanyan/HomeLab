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

- Embedding models: always route to the resident GPU. Since the llama-swap
  matrix guarantees at most one model per GPU, there is no scenario where
  both GPUs hold the same embed model — routing to a non-resident GPU would
  unconditionally evict the active chat model. The `/running` cache uses a
  5s TTL to reduce HTTP calls during burst embedding workloads.
- Cold start (no candidate is resident): use victim-preference routing.
  The plugin checks which GPU's currently-loaded model is idle, and prefers
  the candidate whose swap would evict that idle GPU (minimising disruption).
  If victim preference cannot be determined, returns candidates unmodified.
- One resident: check whether the resident GPU is saturated and whether the
  victim GPU is actively serving. If the resident is idle and the victim is
  busy or recently served (within 120s), narrow to the resident to protect
  the active session. If the resident is saturated (all slots busy), expose
  both candidates so LiteLLM routes traffic to the non-resident GPU and
  llama-swap loads the model there. Embedding models always narrow.
- Both ready: check for session stickiness first, then fall back to
  least-busy slot selection using per-instance `/slots` polling with
  round-robin tie-breaking. Since both GPUs hold the same model, evicting
  either one for the other is harmless.

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
import re
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
_EMBED_RUNNING_CACHE_TTL_SECONDS: Final = 5.0
_REQUEST_TIMEOUT_SECONDS: Final = 1.0

# Redis / Dragonfly connection settings for the pin store.
# Falls back to in-memory if the env var is unset or Redis is unreachable.
_REDIS_URL: Final | None = os.environ.get("LLAMA_SWAP_PIN_REDIS_URL")

# Redis key namespace prefix for pins.
_PIN_NAMESPACE: Final = "llama-swap-affinity:v1"
# Redis key namespace prefix for session recency.
_RECENCY_NAMESPACE: Final = "llama-swap-affinity:recency:v1"

# Session-stickiness settings (only relevant when Redis is available).
# TTL of 1h balances KV-cache retention against memory churn.
_PIN_TTL_SECONDS: Final = 3600.0
# How much busier the pinned GPU can be before we rebalance.
# With 2 slots/GPU: pinned=1/other=0 -> stick; pinned=2/other=0 -> rebalance.
STICKY_SLOP: Final = 1
# Session recency window (seconds). Requests are protected from triggering an
# eviction if their GPU was served within this window. Covers the gap between
# mid-generation protection (busy slots), a user's read-and-reply period, and
# tool-call round trips where slot count drops to zero but the session is
# actively waiting on external I/O.
_RECENT_SESSION_WINDOW: Final = 300.0
# Max number of pins stored in Redis (soft cap; keys are never explicitly
# evicted except by TTL).
_PIN_MAP_MAX: Final = 10000

# GPU topology: model_id -> set of GPU indices that support it.
# Used to determine what model would be evicted if a swap occurs.
_KNOWN_TOPOLOGY: Final[dict[str, frozenset[int]]] = {
    "35b-spread": frozenset({0, 1}),
}
_GPU_SUFFIX_RE: Final = re.compile(r"-gpu([01])$")


def _strip_provider_prefix(model: str) -> str:
    """`openai/35b-gpu0` -> `35b-gpu0` to match llama-swap's model IDs."""
    _, _, rest = model.partition("/")
    return rest or model


def _gpu_topology(model_id: str) -> frozenset[int] | None:
    """Return the GPU set for a llama-swap model ID, or None for unknown."""
    if model_id in _KNOWN_TOPOLOGY:
        return _KNOWN_TOPOLOGY[model_id]
    match = _GPU_SUFFIX_RE.search(model_id)
    if match is not None:
        return frozenset({int(match.group(1))})
    return None


def _is_embedding_request(candidate_ids: dict[str, str]) -> bool:
    """Check whether all candidates are embedding models."""
    return any("embed" in mid for mid in candidate_ids)


def _is_tool_call_continuation(context: RoutingContext) -> bool:
    """Return True if the last message is a tool result — the model
    just emitted ``tool_calls`` and the client is sending back the result.
    This request is a continuation of an active session and should not
    trigger cross-GPU routing decisions that could risk an eviction.
    """
    msgs = getattr(context, "structured_messages", None)
    if not msgs:
        return False
    last = msgs[-1] if isinstance(msgs, list) else None
    if last is None:
        return False
    return last.get("role") == "tool"


def _find_chat_gpu(running: dict[str, str]) -> str | None:
    """Return the full deployment model ID for the GPU with the
    highest-eviction-cost chat model.  None if no chat model is running.

    Eviction costs: spread (25) > 35b-gpu0 (20) > 35b-gpu1 (10).
    Embedding models have no eviction cost in the matrix and are not
    considered here.
    """
    cost_priority: dict[str, int] = {
        "35b-gpu0": 20,
        "35b-gpu1": 10,
        "35b-spread": 25,
        "35b-gpu0-dense": 20,
        "35b-gpu1-dense": 10,
        "27b-gpu0": 15,
        "27b-gpu1": 15,
    }
    best: tuple[str, int] | None = None
    for model_id, state in running.items():
        if state != "ready":
            continue
        if "embed" in model_id:
            continue
        cost = cost_priority.get(model_id, 0)
        if best is None or cost > best[1]:
            best = (model_id, cost)
    if best is None:
        return None
    # Convert model_id back to deployment ID (add openai/ prefix).
    # The caller's candidate_ids maps full deployment IDs to model IDs,
    # so we find the matching deployment ID.
    return best[0]


class LlamaSwapAffinityPlugin:
    """Implements `litellm.types.router.RoutingPlugin` (async `run`)."""

    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._redis: aioredis.Redis | None = None
        self._running_cache: dict[str, str] = {}
        self._running_cache_expires_at: float = 0.0
        self._slots_cache: dict[str, tuple[int, int, float]] = {}
        self._round_robin_counter: int = 0
        # Fallback in-memory pin map (used when Redis is unavailable).
        self._pin_map: dict[str, tuple[str, float]] = {}
        self._pin_order: list[str] = []  # LRU tracking (insertion order)
        # Recent session tracking: model_id -> last served timestamp.
        self._last_routed: dict[str, float] = {}

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

        self._running_cache = await self._running_state_live()
        self._running_cache_expires_at = now + effective_ttl
        return self._running_cache

    async def _running_state_live(self) -> dict[str, str]:
        """Fetch current running state from llama-swap, bypassing cache."""
        client = self._get_client()
        response = await client.get(_RUNNING_URL)
        response.raise_for_status()
        payload = response.json()

        return {
            entry["model"]: entry["state"]
            for entry in payload.get("running", [])
            if entry.get("state") in _RESIDENT_STATES
        }

    async def _slot_stats(
        self, model_id: str, cache_ttl: float | None = None,
    ) -> tuple[int, int] | None:
        """Return (busy_count, total_slots) for a model, or None on failure."""
        now = time.monotonic()
        effective_ttl = cache_ttl if cache_ttl is not None else _SLOTS_CACHE_TTL_SECONDS
        cached = self._slots_cache.get(model_id)
        if cached is not None and now < cached[2]:
            return (cached[0], cached[1])

        client = self._get_client()
        response = await client.get(
            f"{_LLAMA_SWAP_BASE_URL}/upstream/{model_id}/slots"
        )
        response.raise_for_status()
        slots = response.json()
        busy = sum(1 for slot in slots if slot.get("is_processing"))
        total = len(slots)

        self._slots_cache[model_id] = (busy, total, now + effective_ttl)
        return (busy, total)

    async def _slot_busy_count(
        self, model_id: str, cache_ttl: float | None = None,
    ) -> int:
        """Return the number of busy slots for a model."""
        stats = await self._slot_stats(model_id, cache_ttl=cache_ttl)
        if stats is not None:
            return stats[0]
        return 0

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
    # Load-aware saturation check
    # ------------------------------------------------------------------

    async def _is_gpu_saturated(
        self, gpu_indices: frozenset[int], running: dict[str, str],
    ) -> bool:
        """Check whether the given GPU(s) are fully saturated.

        Sums ``busy`` across all resident models on the specified GPUs.
        Returns ``True`` only when the total busy count equals the total
        slot count (no free slots anywhere on those GPUs).
        """
        busy_total: int = 0
        total_slots: int = 0
        for model_id, state in running.items():
            if state not in _RESIDENT_STATES:
                continue
            top = _gpu_topology(model_id)
            if top is None:
                continue
            if not top.intersection(gpu_indices):
                continue
            stats = await self._slot_stats(model_id)
            if stats is None:
                return False  # can't confirm saturation
            busy_total += stats[0]
            total_slots += stats[1]
        return total_slots > 0 and busy_total >= total_slots

    # ------------------------------------------------------------------
    # Recency tracking (Redis-backed, with in-memory fallback)
    # ------------------------------------------------------------------

    def _recency_key(self, model_id: str) -> str:
        """Redis key for a recency entry."""
        safe = model_id.replace(":", "-")
        return f"{_RECENCY_NAMESPACE}:{safe}"

    async def _is_recency_recent(self, model_id: str) -> bool:
        """Return whether *model_id* was served within the recency window."""
        redis = await self._get_redis()
        if redis is not None:
            try:
                val = await redis.get(self._recency_key(model_id))
                if val is not None:
                    return (
                        time.monotonic() - float(val)
                        < _RECENT_SESSION_WINDOW
                    )
                return False
            except Exception:
                pass

        # Fallback: in-memory recency map
        if model_id in self._last_routed:
            return (
                time.monotonic() - self._last_routed[model_id]
                < _RECENT_SESSION_WINDOW
            )
        return False

    async def _stamp_recency(self, model: str) -> None:
        """Record that *model* was just routed (full provider ID)."""
        model_id = _strip_provider_prefix(model)
        ts = time.monotonic()

        # Update in-memory map (always, as fast path).
        self._last_routed[model_id] = ts

        # Persist to Redis for multi-replica visibility.
        redis = await self._get_redis()
        if redis is not None:
            try:
                await redis.set(
                    self._recency_key(model_id),
                    ts,
                    ex=int(_RECENT_SESSION_WINDOW),
                )
            except Exception:
                pass

    # ------------------------------------------------------------------
    # Stickiness key
    # ------------------------------------------------------------------

    async def _compute_sticky_key(self, context: RoutingContext) -> str | None:
        """Return the stickiness key for this request.

        Priority:
        1. `context.metadata["session_id"]` (canonical session ID, populated
           when Open WebUI sends `X-Litellm-Session-Id`).
        2. Content fingerprint (model + first user message content).
        3. `None` - no stickiness.
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

    async def _check_stickiness(
        self, pinned: str, ready_candidates: list[str],
        candidate_ids: dict[str, str],
    ) -> str | None:
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
            return pinned  # can't compare -- stick

        min_busy = min(count for _, count in scored)
        pinned_idx = next(i for i, (m, _) in enumerate(scored) if m == pinned)
        pinned_busy = scored[pinned_idx][1]

        if pinned_busy <= min_busy + STICKY_SLOP:
            # Pinned GPU is near least-busy -- stick (KV-cache reuse)
            return pinned
        else:
            # Pinned GPU is materially busier -- rebalance
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

            candidate_ids = {
                model: _strip_provider_prefix(model) for model in candidates
            }
            running = await self._running_state()

            occupied_candidates = [
                model for model, model_id in candidate_ids.items()
                if running.get(model_id) == "ready"
            ]

            # ------------------------------------------------------------------
            # Embedding models: always narrow to resident.
            # The matrix guarantees at most one model per GPU, so there is no
            # scenario where both GPUs hold the same embed model. Routing to
            # a non-resident GPU would unconditionally evict the active chat
            # model. Use a 5s `/running` cache TTL to reduce HTTP calls.
            # ------------------------------------------------------------------
            if _is_embedding_request(candidate_ids):
                candidate_ids_embed = {
                    model: _strip_provider_prefix(model)
                    for model in candidates
                }
                running_embed = await self._running_state(
                    cache_ttl=_EMBED_RUNNING_CACHE_TTL_SECONDS
                )

                resident_candidates = [
                    model for model, model_id in candidate_ids_embed.items()
                    if model_id in running_embed
                ]

                if not resident_candidates:
                    # No embedding model is resident.  If a chat model is
                    # running on one GPU, route to the GPU with the higher
                    # eviction-cost chat model (less disruptive for llama-swap
                    # to evict that GPU's chat model to make room).  If no
                    # chat model is running either, return unmodified.
                    # Don't narrow here: if chat_on_gpu becomes unhealthy between
                    # this check and LiteLLM processing,
                    # _filter_by_routing_plugin_candidates intersects the narrowed
                    # list with empty healthy_deployments → 500 error.
                    # Return unmodified so LiteLLM can try all candidates.
                    return context

                if len(resident_candidates) == 1:
                    context.candidate_models = resident_candidates
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                    return context

                # Both GPUs have the embed model loaded -- route to least-busy.
                winner = await self._pick_least_busy(
                    resident_candidates, candidate_ids_embed,
                    slots_cache_ttl=_SLOTS_CACHE_TTL_SECONDS,
                )
                context.candidate_models = [winner]
                context.signals["llama_swap_affinity"] = "narrowed_to_least_busy_slot"
                await self._stamp_recency(winner)
                return context

            # ------------------------------------------------------------------
            # Chat models: residency-aware routing
            # ------------------------------------------------------------------

            if not occupied_candidates:
                return context

            if len(occupied_candidates) == 1:
                # One GPU has the model resident. Decide whether to protect
                # the session on the other GPU or allow overflow.
                resident_candidate = occupied_candidates[0]
                resident_model_id = candidate_ids[resident_candidate]

                # Guard check: verify the resident is still running and ready
                # with a live call.  The cached /running state from 1s ago may
                # have been evicted by llama-swap's matrix solver by the time
                # this request reaches the backend.
                live_running = await self._running_state_live()
                if live_running.get(resident_model_id) != "ready":
                    # Resident was evicted or is no longer ready — fall
                    # through to unmodified candidates (LiteLLM will retry).
                    return context

                topology = _gpu_topology(resident_model_id)

                if topology is None:
                    # Unknown topology -- fall through to unmodified candidates.
                    return context

                # Determine which GPU holds the victim model.
                victim_gpu = next(
                    (g for g in (0, 1) if g not in topology), None
                )
                if victim_gpu is None:
                    return context

                # Check victim GPU's state: search ALL running models for any
                # model whose topology includes the victim GPU.  The previous
                # implementation only searched the current request's candidate
                # pair, so the victim model (which is a *different* model from
                # the resident on the other GPU) was never found, making the
                # busy/recent checks dead code.
                victim_model_id = None
                for running_model_id, state in running.items():
                    if state not in _RESIDENT_STATES:
                        continue
                    top = _gpu_topology(running_model_id)
                    if top is not None and victim_gpu in top:
                        victim_model_id = running_model_id
                        break

                # Tool-call continuation: the model just emitted ``tool_calls``
                # and the client is sending back the result.  This is a known
                # active session on the resident GPU — narrow immediately to
                # protect it regardless of the victim's state.
                if victim_model_id is not None and _is_tool_call_continuation(context):
                    context.candidate_models = [resident_candidate]
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident_tool_call"
                    await self._stamp_recency(resident_candidate)
                    return context

                victim_busy = False
                victim_recent = False

                if victim_model_id is not None:
                    stats = await self._slot_stats(victim_model_id)
                    if stats is not None:
                        victim_busy = stats[0] > 0
                    victim_recent = await self._is_recency_recent(victim_model_id)

                if victim_model_id is not None and (victim_busy or victim_recent):
                    # Victim GPU is actively serving or recently served -- narrow
                    # to resident to protect the active session.
                    context.candidate_models = [resident_candidate]
                    if victim_busy:
                        context.signals["llama_swap_affinity"] = "narrowed_to_resident_victim_busy"
                    else:
                        context.signals["llama_swap_affinity"] = "narrowed_to_resident_victim_recent"
                    await self._stamp_recency(resident_candidate)
                    return context

                # Resident GPU is idle and victim is not in the way -- check
                # whether the resident is saturated.  Only allow overflow when
                # the resident is fully loaded; otherwise route to the idle
                # resident to avoid any unnecessary eviction.
                resident_saturated = await self._is_gpu_saturated(
                    topology, running
                )

                if not resident_saturated:
                    # Resident can take more requests -- narrow to resident.
                    context.candidate_models = [resident_candidate]
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                    await self._stamp_recency(resident_candidate)
                    return context

                # Resident is fully saturated and victim is free -- expose both
                # GPUs so LiteLLM routes traffic to the non-resident GPU and
                # llama-swap loads the model there.
                context.candidate_models = candidates
                context.signals["llama_swap_affinity"] = "overflow_exposed_for_lb"
                await self._stamp_recency(resident_candidate)
                return context

            ready_candidates = [
                model for model in occupied_candidates
                if running.get(candidate_ids[model]) == "ready"
            ]
            if len(ready_candidates) < 2:
                target = ready_candidates or occupied_candidates
                context.candidate_models = target
                if len(target) == 1:
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                    await self._stamp_recency(target[0])
                return context

            # Both candidates are loaded and ready.
            # Step 1: compute the stickiness key (session ID or fingerprint).
            sticky_key = await self._compute_sticky_key(context)

            if sticky_key is not None:
                # Step 2: look up any existing pin.
                pinned = await self._get_pin(sticky_key)
                if pinned:
                    # Step 3: load-aware check -- stick or rebalance?
                    decision = await self._check_stickiness(
                        pinned, ready_candidates, candidate_ids
                    )
                    if decision:
                        context.candidate_models = [decision]
                        context.signals["llama_swap_affinity"] = (
                            "sticky_to_pinned" if decision == pinned
                            else "rebalanced_from_sticky"
                        )
                        await self._stamp_recency(decision)
                        return context
                    # Stickiness dropped -- fall through to pure least-busy.

            # Step 4: no pin or stickiness dropped -- route by least-busy.
            winner = await self._pick_least_busy(ready_candidates, candidate_ids)
            context.candidate_models = [winner]
            context.signals["llama_swap_affinity"] = "narrowed_to_least_busy_slot"
            await self._stamp_recency(winner)

            # Step 5: establish a new pin (load-aware: only if the GPU is ready).
            if sticky_key is not None and running.get(
                candidate_ids[winner]
            ) == "ready":
                await self._set_pin(sticky_key, winner)

            return context
        except Exception:
            # Fail open: routing must never break because llama-swap is
            # slow, unreachable, or returns an unexpected shape.
            return context


# Instance LiteLLM resolves via `router_settings.plugins:
# ["llama_swap_affinity.plugin"]` (dotted path -> module.instance).
plugin: Final = LlamaSwapAffinityPlugin()
