"""LiteLLM routing plugin: prefer llama-swap deployments that are already
resident (loaded) over deployments that would force llama-swap's matrix
solver to evict a *different* model family to make room.

Problem this solves
--------------------
All qwen3.6-35b-a3b / qwen3.6-27b / qwen3.6-coder-30b-a3b deployments share
one llama-swap pod with two GPUs. LiteLLM's `least-busy` routing_strategy
picks a deployment purely from its own in-flight-request counter; it has no
idea which GPU already has a given model loaded. Left alone, this can send
(e.g.) a 27B request to the GPU currently serving a busy 35B request,
forcing llama-swap to evict the 35B instance mid-stream.

This plugin narrows the routing-plugin candidate list (see
`litellm.types.router.RoutingContext`) to deployments llama-swap already has
resident, but only when some other, unrelated model is also resident (i.e.
there is something to protect). If nothing conflicting is running, the
candidate list is left untouched so `least-busy` continues to spread load
normally (e.g. across both 35B copies when only 35B is loaded).

Wiring
------
Registered via `router_settings.plugins` in litellm.yaml as
`llama_swap_affinity.plugin`. LiteLLM resolves that dotted path relative to
the directory containing the config file (`/etc/litellm`), where this file
is mounted alongside litellm.yaml by the same ConfigMap - no image build
required. See `litellm.proxy.types_utils.utils.get_instance_fn`.

Requires `router_settings.disable_cooldowns: true` (see litellm.yaml): if a
deployment this plugin narrows to were ever in a LiteLLM failure cooldown,
the intersection with `healthy_deployments` would be empty and the request
would hard-fail instead of falling back. llama-swap's own process state
(`ready` / `starting` / ...) is a better health signal for a single
co-located backend than LiteLLM's failure-count cooldowns are, so those are
disabled globally.
"""

from __future__ import annotations

import os
import time
from typing import Final

import httpx

from litellm.types.router import RoutingContext

_LLAMA_SWAP_BASE_URL: Final = os.environ.get(
    "LLAMA_SWAP_BASE_URL", "http://llama-swap-svc.llm.svc.cluster.local:8080"
)
_RUNNING_URL: Final = f"{_LLAMA_SWAP_BASE_URL.rstrip('/')}/running"

# Process states in which llama-swap considers a model available to serve
# (or about to be) - see internal/process/process.go ProcessState.
_RESIDENT_STATES: Final = frozenset({"ready", "starting"})

# How long to trust a cached /running response before re-fetching. Short
# enough to react to swaps within a request or two, long enough that a burst
# of concurrent requests doesn't hammer llama-swap with duplicate polls.
_CACHE_TTL_SECONDS: Final = 1.0

# Total budget for the /running call. On timeout or any other error the
# plugin fails open (candidate list returned unmodified) so a llama-swap
# hiccup never blocks routing.
_REQUEST_TIMEOUT_SECONDS: Final = 1.0


def _strip_provider_prefix(model: str) -> str:
    """`openai/35b-gpu0` -> `35b-gpu0` to match llama-swap's model IDs."""
    _, _, rest = model.partition("/")
    return rest or model


class LlamaSwapAffinityPlugin:
    """Implements `litellm.types.router.RoutingPlugin` (async `run`)."""

    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._cache_resident: frozenset[str] = frozenset()
        self._cache_expires_at: float = 0.0

    def _get_client(self) -> httpx.AsyncClient:
        # Built lazily inside `run()`, never at import time: this module is
        # exec'd by `get_instance_fn` during config load, which may happen
        # before any asyncio event loop exists.
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=_REQUEST_TIMEOUT_SECONDS)
        return self._client

    async def _resident_models(self) -> frozenset[str]:
        now = time.monotonic()
        if now < self._cache_expires_at:
            return self._cache_resident

        client = self._get_client()
        response = await client.get(_RUNNING_URL)
        response.raise_for_status()
        payload = response.json()

        resident = frozenset(
            entry["model"] for entry in payload.get("running", []) if entry.get("state") in _RESIDENT_STATES
        )
        self._cache_resident = resident
        self._cache_expires_at = now + _CACHE_TTL_SECONDS
        return resident

    async def run(self, context: RoutingContext) -> RoutingContext:
        try:
            candidates = context.candidate_models
            if len(candidates) < 2:
                return context  # nothing to choose between

            candidate_ids = {model: _strip_provider_prefix(model) for model in candidates}
            resident = await self._resident_models()

            resident_candidate_models = [model for model, model_id in candidate_ids.items() if model_id in resident]

            # Is anything running that is NOT part of this request's own
            # candidate set? If not, there's nothing to protect - let
            # least-busy make its normal choice (e.g. spread across both
            # copies of the same model when only that model is loaded).
            foreign_resident = resident - set(candidate_ids.values())
            if not foreign_resident:
                return context

            # Something else is loaded. Prefer whichever of our candidates is
            # already resident, so we don't force llama-swap to evict that
            # foreign model. Never narrow to an empty list - if none of our
            # candidates are resident, fall through unchanged and let the
            # normal strategy (and the GPU-preference ordering in
            # litellm.yaml) decide, same as the cold-start case.
            if resident_candidate_models:
                context.candidate_models = resident_candidate_models
                context.signals["llama_swap_affinity"] = "narrowed_to_resident"

            return context
        except Exception:
            # Fail open: routing must never break because llama-swap's
            # /running endpoint is slow, unreachable, or returns an
            # unexpected shape.
            return context


# Instance LiteLLM resolves via `router_settings.plugins:
# ["llama_swap_affinity.plugin"]` (dotted path -> module.instance).
plugin: Final = LlamaSwapAffinityPlugin()
