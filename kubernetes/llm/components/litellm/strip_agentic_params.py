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
import re
import shlex
from typing import Any

from litellm._logging import verbose_proxy_logger as logger
from litellm.integrations.custom_logger import CustomLogger

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

# A single turn (reasoning + tool call) is normally well under 4K tokens. With no
# cap and a 262K context, one degenerate generation can run for many minutes and
# hold the whole run until AgentTimeout, so cap every agentic request.
MAX_COMPLETION_TOKENS = 8192

# Turn steering. The sandbox's own max-turns cap just fails the run, and the
# model tends to keep calling skill scripts instead of concluding. Count the
# tool-calling turns so far, ask the model to wrap up, and past a point remove
# the tools so it has to answer (the JSON conversion then runs as usual).
NUDGE_AFTER_TURNS = 20
FORCE_FINISH_AFTER_TURNS = 25
NUDGE_NOTE = (
    "[Investigation budget: you have used {turns} tool-calling steps. Wrap up "
    "soon. Only run another command if it is essential to the diagnosis, then "
    "write your final analysis.]"
)
FORCE_NOTE = (
    "[Investigation budget exhausted after {turns} steps. Tools are no longer "
    "available. Write your final analysis now from the evidence gathered so far, "
    "and state clearly anything you could not verify.]"
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


# Shell tool names models invent. The Lightspeed sandbox only registers the
# shell capability as `exec_command` with a `cmd` argument, and the openai-agents
# SDK treats any unknown tool name as fatal. The `investigate-alert` skill tells
# the model to run `bash scripts/query-alert.sh ...`, so Qwen calls a tool named
# `bash` (or even a tool whose *name* is the whole command line).
SHELL_TOOL_NAMES = frozenset(
    ("bash", "shell", "sh", "zsh", "fish", "run_shell", "execute_command", "run_command")
)
# Qwen sometimes puts the whole command line in the tool name, with its own
# tool-call markup leaking in (`oc get pdb -n argocd -o yaml\n</parameter>`).
CLI_COMMANDS = frozenset(
    ("oc", "kubectl", "jq", "find", "ls", "cat", "grep", "curl", "head", "tail", "echo", "awk", "sed")
)
MARKUP_RE = re.compile(r"</?(?:parameter|function|tool_call|invoke)[^>]*>")
SHELL_TOOL_TARGET = "exec_command"
SHELL_CMD_KEYS = ("command", "script", "code", "cmd_str", "commandline")


SCRIPT_NAME_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


def _script_call(name: str, arguments: str | None) -> tuple[str, str] | None:
    """The model used a skill script name (get_events.sh) as the tool name.

    Only plain file names are rewritten, and the name and every argument are
    shell-quoted, so model output cannot inject extra shell syntax.
    """
    if not SCRIPT_NAME_RE.match(name):
        return None
    try:
        parsed = json.loads(arguments or "")
    except ValueError:
        parsed = (arguments or "").strip()
    if isinstance(parsed, dict):
        args = [str(v) for v in parsed.values() if isinstance(v, (str, int))]
    elif isinstance(parsed, list):
        args = [str(v) for v in parsed]
    elif isinstance(parsed, str) and parsed:
        args = shlex.split(parsed) if parsed.count('"') % 2 == 0 and parsed.count("'") % 2 == 0 else [parsed]
    else:
        args = []
    quoted_args = " ".join(shlex.quote(a) for a in args)
    if "/" in name:
        cmd = f"bash {shlex.quote(name)} {quoted_args}"
    else:
        finder = f"find / -name {shlex.quote(name)} -path '*skills*' 2>/dev/null | head -1"
        cmd = f'bash "$({finder})" {quoted_args}'
    return SHELL_TOOL_TARGET, json.dumps({"cmd": cmd.strip()})


def _normalize_shell_call(name: str | None, arguments: str | None) -> tuple[str, str] | None:
    """Return (exec_command, arguments_json) for a shell-style tool call.

    Returns None when the call is not shell-style, or already correct.
    """
    name = (name or "").strip()
    if not name or name == SHELL_TOOL_TARGET:
        return None
    first = name.split(None, 1)[0].lower()
    if first in CLI_COMMANDS and first not in SHELL_TOOL_NAMES:
        cmd = MARKUP_RE.sub("", name).strip()
        return SHELL_TOOL_TARGET, json.dumps({"cmd": cmd})
    if " " not in name and (name.endswith(".sh") or "/" in name):
        return _script_call(name, arguments)
    if first not in SHELL_TOOL_NAMES:
        return None

    raw = (arguments or "").strip()
    parsed: Any = None
    if raw:
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = raw  # plain text arguments, treat as the command itself

    if " " in name:
        # The model put the whole command line in the tool name.
        args: dict = {"cmd": name}
        if isinstance(parsed, dict):
            for key, value in parsed.items():
                if key not in SHELL_CMD_KEYS and key != "cmd":
                    args[key] = value
    elif isinstance(parsed, dict):
        args = dict(parsed)
        for key in SHELL_CMD_KEYS:
            if key in args and "cmd" not in args:
                args["cmd"] = args.pop(key)
            else:
                args.pop(key, None)
    elif isinstance(parsed, list):
        args = {"cmd": " ".join(str(part) for part in parsed)}
    elif isinstance(parsed, str):
        args = {"cmd": parsed}
    else:
        return None  # nothing to run

    if isinstance(args.get("cmd"), list):
        args["cmd"] = " ".join(str(part) for part in args["cmd"])
    return SHELL_TOOL_TARGET, json.dumps(args)


def _patch_message_tool_calls(message: Any) -> int:
    """Non-streaming: rewrite shell-style tool calls on a response message."""
    patched = 0
    for call in getattr(message, "tool_calls", None) or []:
        function = getattr(call, "function", None)
        if function is None:
            continue
        result = _normalize_shell_call(getattr(function, "name", None), getattr(function, "arguments", None))
        if result:
            logger.warning("rewrote shell tool call %r to %s", (function.name or "")[:80], result[0])
            function.name, function.arguments = result
            patched += 1
    return patched


def _patch_stream_tool_calls(chunks: list) -> int:
    """Streaming: rebuild each tool call from all its chunks, then rewrite it.

    A tool call's name and arguments are split across chunks, so it can only be
    judged once the whole turn is buffered. The corrected name and arguments are
    written into the first chunk of the call and later chunks are blanked.
    """
    calls: dict[int, dict] = {}
    for chunk in chunks:
        choice = _first_choice(chunk)
        delta = getattr(choice, "delta", None) if choice else None
        for call in getattr(delta, "tool_calls", None) or []:
            function = getattr(call, "function", None)
            if function is None:
                continue
            index = getattr(call, "index", 0) or 0
            entry = calls.setdefault(index, {"name": "", "args": "", "first": function, "rest": []})
            if getattr(function, "name", None):
                entry["name"] += function.name
            if getattr(function, "arguments", None):
                entry["args"] += function.arguments
            if function is not entry["first"]:
                entry["rest"].append(function)

    patched = 0
    for entry in calls.values():
        result = _normalize_shell_call(entry["name"], entry["args"])
        if not result:
            continue
        logger.warning("rewrote shell tool call %r to %s", entry["name"][:80], result[0])
        entry["first"].name, entry["first"].arguments = result
        for function in entry["rest"]:
            function.arguments = ""
        patched += 1
    return patched


async def _collect_stream(response: Any) -> tuple[list, bool, list[str]]:
    """Buffer a streamed turn. Returns (chunks, has_tool_calls, answer_parts)."""
    chunks: list[Any] = []
    has_tool_calls = False
    answer_parts: list[str] = []
    async for chunk in response:
        chunks.append(chunk)
        choice = _first_choice(chunk)
        delta = getattr(choice, "delta", None) if choice else None
        if delta is None:
            continue
        if getattr(delta, "tool_calls", None):
            has_tool_calls = True
        if getattr(delta, "content", None):
            answer_parts.append(delta.content)
    return chunks, has_tool_calls, answer_parts


# --- Streaming path ---
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


def _rbac_rules() -> dict:
    str_list = {"type": "array", "items": {"type": "string"}, "minItems": 1}
    rule = {
        "type": "object",
        "properties": {
            "apiGroups": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "resources": str_list,
            "verbs": str_list,
            "resourceNames": str_list,
            "namespace": {"type": "string"},
            "justification": {"type": "string", "minLength": 1},
        },
        "required": ["apiGroups", "resources", "verbs", "justification"],
        "additionalProperties": False,
    }
    return {"type": "array", "items": rule}


# The CRD only accepts these two keys. The model invented `clusterRoles`, which
# the API server prunes, leaving an empty rbac object and a 422.
RBAC_SCHEMA = {
    "type": "object",
    "properties": {"namespaceScoped": _rbac_rules(), "clusterScoped": _rbac_rules()},
    "additionalProperties": False,
}

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
        option["rbac"] = copy.deepcopy(RBAC_SCHEMA)
        plan = option["remediationPlan"]
        plan["properties"]["actions"].setdefault("minItems", 1)
        plan["properties"]["actions"].setdefault("maxItems", 50)
        _close_object(plan, {"risk": RISK})
        _close_object(option["diagnosis"], {"confidence": CONFIDENCE})
        if isinstance(schema["properties"].get("diagnosis"), dict):
            _close_object(schema["properties"]["diagnosis"], {"confidence": CONFIDENCE})
    except (KeyError, TypeError) as exc:
        logger.warning("could not align response_format with the CRD (%r); keys: %s", exc,
                       list(((response_format.get("json_schema") or {}).get("schema") or {}).get("properties", {})))
    return fixed


def _prune_empty(value: Any) -> Any:
    """Recursively drop None and empty lists/dicts; empty-string dict values too.

    Empty strings inside lists are kept: the core API group is `[""]` and the
    CRD accepts it.
    """
    if isinstance(value, dict):
        for key in list(value):
            value[key] = _prune_empty(value[key])
            if value[key] in (None, "", [], {}):
                del value[key]
    elif isinstance(value, list):
        value[:] = [item for item in (_prune_empty(i) for i in value) if item not in (None, [], {})]
    return value


RBAC_REQUIRED = ("apiGroups", "resources", "verbs", "justification")


def _rbac_rule_complete(rule: Any) -> bool:
    """The CRD requires these four fields, each non-empty."""
    if not isinstance(rule, dict):
        return False
    pruned = _prune_empty(dict(rule))
    return all(pruned.get(key) for key in RBAC_REQUIRED)


def _drop_empty_rbac(text: str) -> str:
    """Remove empty/null rbac content from options.

    The CRD requires `options[].rbac` to have at least one property, but the
    model emits `rbac: {}` or `rbac: {"clusterScoped": null}`. The sandbox only
    strips empty values, not nulls, and the API server drops nulls before it
    validates, so an all-null rbac fails with HTTP 422.
    """
    try:
        parsed = json.loads(text)
        options = parsed.get("options") if isinstance(parsed, dict) else None
        if not isinstance(options, list):
            return text
        changed = False
        for option in options:
            if isinstance(option, dict) and "rbac" in option:
                before = json.dumps(option["rbac"], sort_keys=True)
                rbac = option["rbac"]
                if isinstance(rbac, dict):
                    unknown = [k for k in rbac if k not in RBAC_SCHEMA["properties"]]
                    if unknown:
                        logger.warning("dropping rbac keys the CRD does not allow: %s", unknown)
                    for key in unknown:
                        del rbac[key]
                if isinstance(rbac, dict):
                    for scope in ("namespaceScoped", "clusterScoped"):
                        rules = rbac.get(scope)
                        if isinstance(rules, list):
                            rbac[scope] = [r for r in rules if _rbac_rule_complete(r)]
                rbac = _prune_empty(rbac)
                if not rbac:
                    del option["rbac"]
                    changed = True
                elif json.dumps(rbac, sort_keys=True) != before:
                    changed = True
        return json.dumps(parsed) if changed else text
    except (ValueError, AttributeError):
        return text


async def _convert_to_json(request_data: dict, response_format: dict, answer: str) -> str:
    """Second call: no tools, schema enforced, convert the final answer."""
    # There is no public API to access the router; this internal import is the
    # only way. The image is pinned by digest via Renovate, so the module
    # path is stable. If the import fails the hook already returns the
    # original answer (the caller wraps this in a try/except).
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
    raw = response.choices[0].message.content or ""
    cleaned = _drop_empty_rbac(raw)
    try:
        options = json.loads(cleaned).get("options") or []
        logger.debug(
            "agentic conversion: %d options, rbac per option (raw -> cleaned): %s -> %s",
            len(options),
            [json.dumps(o.get("rbac"))[:80] for o in json.loads(raw).get("options") or []],
            [json.dumps(o.get("rbac"))[:80] for o in options],
        )
    except (ValueError, AttributeError):
        logger.warning("agentic conversion returned non-JSON (%d chars)", len(raw))
    return cleaned


def _count_tool_turns(messages: list) -> int:
    """Number of assistant turns that made at least one tool call."""
    return sum(
        1
        for m in messages
        if isinstance(m, dict) and m.get("role") == "assistant" and m.get("tool_calls")
    )


def _steer_turns(data: dict) -> None:
    """Nudge the model to wrap up, and past a limit take its tools away."""
    messages = data.get("messages")
    if not isinstance(messages, list):
        return
    turns = _count_tool_turns(messages)
    if turns >= FORCE_FINISH_AFTER_TURNS:
        logger.warning("agentic run at %d tool turns: removing tools to force a final answer", turns)
        data.pop("tools", None)
        data.pop("tool_choice", None)
        data.pop("parallel_tool_calls", None)
        messages.append({"role": "user", "content": FORCE_NOTE.format(turns=turns)})
    elif turns >= NUDGE_AFTER_TURNS:
        logger.warning("agentic run at %d tool turns: asking the model to wrap up", turns)
        messages.append({"role": "user", "content": NUDGE_NOTE.format(turns=turns)})


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

        for key in ("max_tokens", "max_completion_tokens"):
            value = data.get(key)
            if isinstance(value, int) and value > MAX_COMPLETION_TOKENS:
                data[key] = MAX_COMPLETION_TOKENS
        if not data.get("max_tokens") and not data.get("max_completion_tokens"):
            data["max_tokens"] = MAX_COMPLETION_TOKENS

        extra_body = data.get("extra_body")
        if not isinstance(extra_body, dict):
            extra_body = {}
            data["extra_body"] = extra_body
        extra_body.setdefault("chat_template_kwargs", {}).setdefault("enable_thinking", False)

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
        _steer_turns(data)
        return data

    async def async_post_call_streaming_iterator_hook(
        self,
        user_api_key_dict: Any,
        response: Any,
        request_data: dict,
    ):
        if not str(request_data.get("model") or "").endswith(AGENTIC_SUFFIX):
            async for chunk in response:
                yield chunk
            return

        # Buffer the turn: shell tool calls are only judgeable once complete, and
        # a turn is the final answer only if it ends without any tool call.
        chunks, has_tool_calls, answer = await _collect_stream(response)
        if has_tool_calls:
            _patch_stream_tool_calls(chunks)

        response_format = _saved_response_format(request_data)
        if has_tool_calls or not response_format:
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
        if not str(data.get("model") or "").endswith(AGENTIC_SUFFIX):
            return response
        response_format = _saved_response_format(data)
        choices = getattr(response, "choices", None)
        if not choices:
            return response
        message = getattr(choices[0], "message", None)
        if message is None:
            return response
        if getattr(message, "tool_calls", None):
            _patch_message_tool_calls(message)
            return response
        if not response_format:
            return response
        try:
            message.content = await _convert_to_json(data, response_format, message.content or "")
        except Exception:
            logger.exception("agentic JSON conversion failed, returning original answer")
        return response


proxy_handler_instance = StripAgenticParams()
