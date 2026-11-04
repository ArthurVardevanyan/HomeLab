"""LiteLLM hook: make OpenShift Lightspeed agentic runs work on vLLM.

The Lightspeed agentic sandbox sends every turn with both `tools` and
`response_format` (json_schema), and marks its built-in tools `strict: true`.
On vLLM this breaks in two ways:

1. `response_format` constrains decoding from the first token, so the model can
   never emit a tool call (vllm-project/vllm#39929). The agent skips
   investigation and answers immediately.
2. `strict: true` tools trigger a structural tag that the guidance backend
   rejects with HTTP 500 `KeyError: 'triggers'` (vllm-project/vllm#55152).

Only model names ending in `-agentic` are touched, and only requests that carry
tools. Every other model alias and client is untouched.

Phase 1 (pre-call): drop `response_format` and `tools[].function.strict`, so
the model can call tools freely. Tool results are capped at
MAX_TOOL_RESULT_CHARS because the sandbox does not limit them (one Prometheus
query returned ~1.8 MB and overflowed the 262k-token context). The whole
history is then compacted to a token budget by `_compact_history`.

Phase 2 (post-call): if the model's turn contains tool calls, it is passed
through unchanged. If it has no tool calls, it is the final answer. Prompt
instructions alone did not make the model answer in JSON, so the hook makes a
second call with the original `response_format` and no tools, asking the model
to convert its answer, and returns that schema-enforced JSON instead.
"""

import copy
import json
import logging
from typing import Any

from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("strip_agentic_params")

AGENTIC_SUFFIX = "-agentic"
METADATA_KEY = "agentic_response_format"

MAX_TOOL_RESULT_CHARS = 20000
TRUNCATION_NOTE = (
    "\n\n[TRUNCATED: output was {total} characters, only the first {kept} are "
    "shown. Narrow the query (filters, label selectors, limit, specific "
    "namespace) and try again.]"
)

# Context budget. vLLM serves 262,144 tokens, but real runs peak at 30-150K
# (median call 32K, fixed floor ~17K for the prompt and 34 tool definitions).
CHARS_PER_TOKEN = 4
CONTEXT_TRIGGER_TOKENS = 75000
CONTEXT_TARGET_TOKENS = 50000
KEEP_RECENT_TOOL_RESULTS = 4
ELIDE_BLOCK = 4
ELIDED_NOTE = (
    "[Older tool result removed to keep the context small. Re-run the tool "
    "if you still need this data.]"
)

CONVERT_INSTRUCTION = (
    "Convert your final answer above into the required JSON structure. Keep "
    "every finding, diagnosis, and remediation action. Every remediation plan "
    "must list its concrete actions. Return only the JSON object."
)


def _truncate(text: str) -> str:
    if len(text) <= MAX_TOOL_RESULT_CHARS:
        return text
    note = TRUNCATION_NOTE.format(total=len(text), kept=MAX_TOOL_RESULT_CHARS)
    return text[:MAX_TOOL_RESULT_CHARS] + note


def _truncate_tool_results(messages: list) -> None:
    for message in messages:
        if not isinstance(message, dict) or message.get("role") != "tool":
            continue
        content = message.get("content")
        if isinstance(content, str):
            message["content"] = _truncate(content)
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    part["text"] = _truncate(part["text"])


def _estimate_tokens(messages: list, tools: Any) -> int:
    try:
        chars = len(json.dumps(messages, default=str)) + len(json.dumps(tools, default=str))
    except (TypeError, ValueError):
        return 0
    return chars // CHARS_PER_TOKEN


def _tool_result_indexes(messages: list) -> list:
    return [
        i
        for i, m in enumerate(messages)
        if isinstance(m, dict)
        and m.get("role") == "tool"
        and m.get("content") != ELIDED_NOTE
    ]


def _compact_history(messages: list, tools: Any) -> int:
    """Keep the prompt under CONTEXT_TRIGGER_TOKENS by eliding old tool results.

    The sandbox resends the whole history on every turn and has no limit of its
    own. Once the estimate passes CONTEXT_TRIGGER_TOKENS, the oldest tool
    results are replaced with a short note until it is under
    CONTEXT_TARGET_TOKENS. The newest KEEP_RECENT_TOOL_RESULTS are never
    touched, and system, user and assistant messages are kept as they are.
    Elision is rounded up to blocks of ELIDE_BLOCK results, so the prompt
    prefix only changes every few turns and vLLM's prefix cache stays useful.
    """
    if _estimate_tokens(messages, tools) <= CONTEXT_TRIGGER_TOKENS:
        return 0
    candidates = _tool_result_indexes(messages)[:-KEEP_RECENT_TOOL_RESULTS]
    elided = 0
    for i in candidates:
        message = messages[i]
        if elided % ELIDE_BLOCK == 0 and _estimate_tokens(messages, tools) <= CONTEXT_TARGET_TOKENS:
            break
        message["content"] = ELIDED_NOTE
        elided += 1
    return elided


def _saved_response_format(request_data: dict) -> Any:
    metadata = request_data.get("metadata")
    if isinstance(metadata, dict):
        return metadata.get(METADATA_KEY)
    return None


RISK = {"type": "string", "enum": ["Low", "Medium", "High", "Critical"]}
CONFIDENCE = {"type": "string", "enum": ["Low", "Medium", "High"]}


def _close_object(obj: dict, extra: dict) -> None:
    """Add CRD-only fields and forbid any other free-form keys."""
    obj.setdefault("properties", {}).update(extra)
    obj["additionalProperties"] = False


def _match_crd(response_format: dict) -> dict:
    """Align the sandbox schema with the AnalysisResult CRD.

    The sandbox schema is looser than the CRD the operator writes to, and each
    gap failed a run with `422 Unprocessable Entity`:

    - `remediationPlan.actions` may be empty, but the CRD requires minItems 1.
    - The CRD has `remediationPlan.risk` and `diagnosis.confidence` enums the
      sandbox schema omits, so the model invented values such as "Low-Medium".
    - The CRD requires `options[].rbac` to have at least one property (it must
      be omitted for advisory-only options), but the model emitted `rbac: {}`.
      That one is fixed after conversion by `_drop_empty_rbac`, because forcing
      a minimum would push the model to invent RBAC for advisory options.
    """
    fixed = copy.deepcopy(response_format)
    try:
        schema = fixed["json_schema"]["schema"]
        options = schema["properties"]["options"]
        options.setdefault("maxItems", 10)
        option = options["items"]["properties"]
        plan = option["remediationPlan"]
        plan["properties"]["actions"].setdefault("minItems", 1)
        plan["properties"]["actions"].setdefault("maxItems", 50)
        _close_object(plan, {"risk": RISK})
        _close_object(option["diagnosis"], {"confidence": CONFIDENCE})
        if isinstance(schema["properties"].get("diagnosis"), dict):
            _close_object(schema["properties"]["diagnosis"], {"confidence": CONFIDENCE})
    except (KeyError, TypeError):
        pass
    return fixed


def _drop_empty_rbac(text: str) -> str:
    """Remove `rbac: {}` from options; the CRD rejects empty rbac objects."""
    try:
        parsed = json.loads(text)
        options = parsed.get("options") if isinstance(parsed, dict) else None
        if not isinstance(options, list):
            return text
        changed = False
        for option in options:
            if isinstance(option, dict) and option.get("rbac") == {}:
                del option["rbac"]
                changed = True
        return json.dumps(parsed) if changed else text
    except (ValueError, AttributeError):
        return text


async def _convert_to_json(request_data: dict, response_format: dict, answer: str) -> str:
    """Second call: no tools, schema enforced, convert the final answer."""
    from litellm.proxy.proxy_server import llm_router

    if llm_router is None:
        raise RuntimeError("LiteLLM router is not initialised")
    response_format = _match_crd(response_format)
    messages = copy.deepcopy(request_data.get("messages") or [])
    messages.append({"role": "assistant", "content": answer or "(no answer text)"})
    messages.append({"role": "user", "content": CONVERT_INSTRUCTION})
    response = await llm_router.acompletion(
        model=request_data["model"],
        messages=messages,
        response_format=response_format,
        stream=False,
    )
    return _drop_empty_rbac(response.choices[0].message.content or "")


def _first_choice(chunk: Any) -> Any:
    choices = getattr(chunk, "choices", None)
    return choices[0] if choices else None


class StripAgenticParams(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> dict:
        model = data.get("model") or ""
        tools = data.get("tools")
        if not model.endswith(AGENTIC_SUFFIX) or not tools:
            return data

        response_format = data.pop("response_format", None)
        if isinstance(response_format, dict) and response_format.get("type") == "json_schema":
            metadata = data.get("metadata")
            if not isinstance(metadata, dict):
                metadata = {}
                data["metadata"] = metadata
            metadata[METADATA_KEY] = response_format
        if isinstance(data.get("messages"), list):
            _truncate_tool_results(data["messages"])
            elided = _compact_history(data["messages"], tools)
            if elided:
                logger.info("elided %d old tool results to fit the context budget", elided)
        for tool in tools:
            function = tool.get("function") if isinstance(tool, dict) else None
            if isinstance(function, dict):
                function.pop("strict", None)
        return data

    async def async_post_call_streaming_iterator_hook(
        self,
        user_api_key_dict: Any,
        response: Any,
        request_data: dict,
    ):
        response_format = _saved_response_format(request_data)
        if not response_format:
            async for chunk in response:
                yield chunk
            return

        # Buffer the turn: we only know it is the final answer once the stream
        # ends without any tool call.
        chunks = []
        has_tool_calls = False
        answer = []
        async for chunk in response:
            chunks.append(chunk)
            choice = _first_choice(chunk)
            delta = getattr(choice, "delta", None) if choice else None
            if delta is None:
                continue
            if getattr(delta, "tool_calls", None):
                has_tool_calls = True
            if getattr(delta, "content", None):
                answer.append(delta.content)

        if has_tool_calls:
            for chunk in chunks:
                yield chunk
            return

        try:
            final_json = await _convert_to_json(request_data, response_format, "".join(answer))
        except Exception:
            logger.exception("agentic JSON conversion failed, returning original answer")
            for chunk in chunks:
                yield chunk
            return

        # Replay the original chunks (role, reasoning, finish_reason, usage) with
        # the answer text replaced by the converted JSON.
        injected = False
        for chunk in chunks:
            choice = _first_choice(chunk)
            delta = getattr(choice, "delta", None) if choice else None
            if delta is not None and getattr(delta, "content", None):
                delta.content = "" if injected else final_json
                injected = True
            elif delta is not None and not injected and getattr(choice, "finish_reason", None):
                delta.content = final_json
                injected = True
            yield chunk

    async def async_post_call_success_hook(
        self,
        data: dict,
        user_api_key_dict: Any,
        response: Any,
    ) -> Any:
        response_format = _saved_response_format(data)
        choices = getattr(response, "choices", None)
        if not response_format or not choices:
            return response
        message = getattr(choices[0], "message", None)
        if message is None or getattr(message, "tool_calls", None):
            return response
        try:
            message.content = await _convert_to_json(data, response_format, message.content or "")
        except Exception:
            logger.exception("agentic JSON conversion failed, returning original answer")
        return response


proxy_handler_instance = StripAgenticParams()
