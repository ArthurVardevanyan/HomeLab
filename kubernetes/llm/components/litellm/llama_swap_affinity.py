"""LiteLLM routing plugin: route between llama-swap deployments of the same
model based on which GPU already has it resident and, when more than one
copy is resident, which one is actually less busy.

Problem this solves
--------------------
All qwen3.6-35b-a3b / qwen3.6-27b / qwen3.6-coder-30b-a3b deployments share
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
- If exactly one candidate is resident: narrow to it. Every other model here
  runs with `ttl: 0` (never expires), so if only one copy is loaded, the
  other GPU is almost certainly running a *different* model - routing there
  would force an unnecessary eviction when an already-loaded copy is right
  there.
- If both candidates are resident and ready: poll llama.cpp's per-instance
  `/slots` endpoint (proxied through llama-swap's `/upstream/<model>/slots`)
  for actual busy-slot counts, and route to whichever has fewer. Ties -
  the common case, since both GPUs are usually idle - are broken with a
  simple round-robin counter, which is what actually fixes the observed
  skew: a load-based comparison that just returns the first candidate on
  every tie is exactly the bug this plugin exists to avoid repeating.

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
import os
import time
from typing import Final

import httpx

from litellm.types.router import RoutingContext

_LLAMA_SWAP_BASE_URL: Final = os.environ.get(
    "LLAMA_SWAP_BASE_URL", "http://llama-swap-svc.llm.svc.cluster.local:8080"
).rstrip("/")
_RUNNING_URL: Final = f"{_LLAMA_SWAP_BASE_URL}/running"

# Process states in which llama-swap considers a model resident (loaded, or
# about to be) - see internal/process/process.go ProcessState. "stopping"
# and "shutdown" are deliberately excluded: a process on its way out isn't
# worth protecting from eviction, and can't serve /slots.
_RESIDENT_STATES: Final = frozenset({"ready", "starting"})

# How long to trust a cached /running response before re-fetching. Short
# enough to react to swaps within a request or two, long enough that a burst
# of concurrent requests doesn't hammer llama-swap with duplicate polls.
_RUNNING_CACHE_TTL_SECONDS: Final = 1.0

# /slots reflects instantaneous llama.cpp slot occupancy, which changes far
# faster than model residency. Cached briefly so a burst of near-simultaneous
# requests shares one poll rather than issuing one each, without going so
# stale that the load comparison becomes meaningless.
_SLOTS_CACHE_TTL_SECONDS: Final = 0.25

# Total budget per llama-swap HTTP call. On timeout or any other error the
# plugin fails open (candidate list returned unmodified, or narrowed only as
# far as residency data allows) so a llama-swap hiccup never blocks routing.
_REQUEST_TIMEOUT_SECONDS: Final = 1.0


def _strip_provider_prefix(model: str) -> str:
    """`openai/35b-gpu0` -> `35b-gpu0` to match llama-swap's model IDs."""
    _, _, rest = model.partition("/")
    return rest or model


class LlamaSwapAffinityPlugin:
    """Implements `litellm.types.router.RoutingPlugin` (async `run`)."""

    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._running_cache: dict[str, str] = {}
        self._running_cache_expires_at: float = 0.0
        self._slots_cache: dict[str, tuple[int, float]] = {}
        self._round_robin_counter: int = 0

    def _get_client(self) -> httpx.AsyncClient:
        # Built lazily inside `run()`, never at import time: this module is
        # exec'd by `get_instance_fn` during config load, which may happen
        # before any asyncio event loop exists.
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=_REQUEST_TIMEOUT_SECONDS)
        return self._client

    async def _running_state(self) -> dict[str, str]:
        """Model ID -> process state, for models in `_RESIDENT_STATES`."""
        now = time.monotonic()
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
        self._running_cache_expires_at = now + _RUNNING_CACHE_TTL_SECONDS
        return state

    async def _slot_busy_count(self, model_id: str) -> int:
        now = time.monotonic()
        cached = self._slots_cache.get(model_id)
        if cached is not None and now < cached[1]:
            return cached[0]

        client = self._get_client()
        response = await client.get(f"{_LLAMA_SWAP_BASE_URL}/upstream/{model_id}/slots")
        response.raise_for_status()
        slots = response.json()
        busy = sum(1 for slot in slots if slot.get("is_processing"))

        self._slots_cache[model_id] = (busy, now + _SLOTS_CACHE_TTL_SECONDS)
        return busy

    async def _pick_least_busy(self, candidates: list[str], candidate_ids: dict[str, str]) -> str:
        """Pick the candidate with fewest busy llama.cpp slots.

        Ties (the common case, since both GPUs are usually idle) are broken
        with a round-robin counter rather than always returning the first
        candidate - that "always first on a tie" behavior is exactly the bug
        this plugin exists to route around.
        """
        counts = await asyncio.gather(
            *(self._slot_busy_count(candidate_ids[model]) for model in candidates),
            return_exceptions=True,
        )
        # A candidate whose /slots poll failed can't be compared - drop it
        # rather than let an exception masquerade as "0 busy" (which would
        # wrongly make it look like the best choice).
        scored = [(model, count) for model, count in zip(candidates, counts) if isinstance(count, int)]
        if not scored:
            return candidates[self._round_robin_counter % len(candidates)]

        min_busy = min(count for _, count in scored)
        least_busy = [model for model, count in scored if count == min_busy]

        winner = least_busy[self._round_robin_counter % len(least_busy)]
        self._round_robin_counter += 1
        return winner

    async def run(self, context: RoutingContext) -> RoutingContext:
        try:
            candidates = context.candidate_models
            if len(candidates) < 2:
                return context  # nothing to choose between

            candidate_ids = {model: _strip_provider_prefix(model) for model in candidates}
            running = await self._running_state()

            occupied_candidates = [model for model, model_id in candidate_ids.items() if model_id in running]

            if not occupied_candidates:
                # Cold start: nothing in this group is loaded. Let the
                # normal strategy and the GPU-preference ordering in
                # litellm.yaml decide.
                return context

            if len(occupied_candidates) == 1:
                # Every model here runs with ttl: 0 (never expires), so if
                # only one copy of this group is loaded, the other GPU is
                # almost certainly serving a different model - protect the
                # resident copy rather than force an unnecessary eviction.
                context.candidate_models = occupied_candidates
                context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                return context

            ready_candidates = [
                model for model in occupied_candidates if running.get(candidate_ids[model]) == "ready"
            ]
            if len(ready_candidates) < 2:
                # One of the two is still "starting" (rare - normally both
                # are already ready via hooks.on_startup.preload) and can't
                # serve /slots yet. Narrow to whichever is actually usable.
                target = ready_candidates or occupied_candidates
                context.candidate_models = target
                if len(target) == 1:
                    context.signals["llama_swap_affinity"] = "narrowed_to_resident"
                return context

            # Both candidates are loaded and ready: route by actual
            # llama.cpp slot occupancy instead of LiteLLM's own counter.
            winner = await self._pick_least_busy(ready_candidates, candidate_ids)
            context.candidate_models = [winner]
            context.signals["llama_swap_affinity"] = "narrowed_to_least_busy_slot"
            return context
        except Exception:
            # Fail open: routing must never break because llama-swap is
            # slow, unreachable, or returns an unexpected shape.
            return context


# Instance LiteLLM resolves via `router_settings.plugins:
# ["llama_swap_affinity.plugin"]` (dotted path -> module.instance).
plugin: Final = LlamaSwapAffinityPlugin()
