"""LiteLLM callback: inject real client IP (X-Forwarded-For) into llama-swap requests.

Problem
-------
OpenWebUI does not forward standard proxy headers (X-Forwarded-For, X-Real-IP)
when making internal API calls to LiteLLM via OPENAI_API_BASE_URL. The
ENABLE_FORWARD_USER_INFO_HEADERS setting only forwards X-OpenWebUI-* headers.

LiteLLM's _get_forwardable_headers() (litellm_pre_call_utils.py) only forwards
x-* prefixed headers (plus anthropic-beta), so X-Forwarded-For would be dropped
anyway even if OpenWebUI included it.

This callback sits in the middle: it reads the real client IP from the original
request headers (available through litellm_params.metadata.request_headers in
the pre_call_hook data dict) and injects X-Forwarded-For into the headers dict
that LiteLLM forwards to llama-swap.

Wiring
------
Registered in litellm.yaml under litellm_settings.callbacks as
"llm_real_ip.callback". Resolved via the dotted-path convention
(litellm.proxy.types_utils.utils.get_instance_fn), same as the
llama_swap_affinity plugin mounted alongside this file at /etc/litellm.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Final

from litellm.integrations.custom_logger import CustomLogger

if TYPE_CHECKING:
    from litellm.caching.caching import DualCache
    from litellm.proxy._types import UserAPIKeyAuth
    from litellm.types.utils import CallTypesLiteral

RealIPHeaders: Final = frozenset(
    {"x-forwarded-for", "x-real-ip", "forwarded", "x-cluster-client-ip"}
)


class RealIPForwarder(CustomLogger):
    """Extract the real client IP from the incoming request and inject it
    as X-Forwarded-For into the headers sent to the LLM API (llama-swap)."""

    async def async_pre_call_hook(
        self,
        user_api_key_dict: "UserAPIKeyAuth",
        cache: "DualCache",
        data: dict[str, Any],
        call_type: "CallTypesLiteral",
    ) -> dict[str, Any] | None:
        # data is the same dict that LiteLLM uses to build the LLM API call.
        # litellm_params.metadata contains:
        #   - request_headers: original HTTP headers from the proxy layer
        #   - headers: headers that will be forwarded to the LLM API (x-* only)

        metadata: dict[str, Any] = data.get("litellm_params", {}).get("metadata", {}) or {}
        real_headers: dict[str, str] = metadata.get("request_headers", {}) or {}
        forward_headers: dict[str, Any] = metadata.get("headers", {}) or {}

        # If X-Forwarded-For is already present in the outgoing headers, leave it
        # alone — another component already handled it.
        existing_ff: str | None
        if isinstance(forward_headers, dict):
            existing_ff = forward_headers.get("X-Forwarded-For") or forward_headers.get("x-forwarded-for")
        else:
            existing_ff = None

        if existing_ff:
            return None

        # Extract the real client IP from the original request headers.
        # X-Forwarded-For format: "client, proxy1, proxy2" — take the first entry.
        real_ip: str | None = None
        xff: str | None = real_headers.get("X-Forwarded-For") or real_headers.get("x-forwarded-for")
        if xff:
            real_ip = xff.split(",")[0].strip()

        if not real_ip:
            # Try X-Real-IP (set by Envoy on the initial request).
            xri: str | None = real_headers.get("X-Real-IP") or real_headers.get("x-real-ip")
            if xri:
                real_ip = xri.strip()

        if not real_ip:
            # Try the "forwarded" header (RFC 7239).
            forwarded: str | None = real_headers.get("Forwarded") or real_headers.get("forwarded")
            if forwarded:
                # For simplicity, take the first "for=" value.
                import re
                for match in re.finditer(r"for=([^;,]+)", forwarded):
                    real_ip = match.group(1).strip()
                    break

        if not real_ip:
            # Last resort: if OpenWebUI forwarded X-OpenWebUI-User-Email (mapped
            # to user_id via user_header_mappings), that's not an IP but we have
            # nothing better.
            return None

        # Inject X-Forwarded-For into the headers dict that LiteLLM will forward
        # to the LLM API. These are merged with the x-* headers in
        # LiteLLMProxyRequestSetup.add_headers_to_llm_call() via the
        # add_litellm_data_to_request path.
        if isinstance(forward_headers, dict):
            forward_headers["X-Forwarded-For"] = real_ip
            data["litellm_params"]["metadata"]["headers"] = forward_headers

        return None


callback: Final = RealIPForwarder()
