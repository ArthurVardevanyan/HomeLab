#!/usr/bin/env python3
"""Fix _synchronize_device CUDA-only no-op in qwen_triton_warmup.py.

``_synchronize_device`` only synchronizes when ``device.type == "cuda"``:

    def _synchronize_device(device: torch.device) -> None:
        if device.type == "cuda":
            torch.accelerator.synchronize(device)

On XPU this is a no-op, so the warmup call site never waits for the
dummy-input Triton kernels it just launched -- a strict correctness bug
(the guard should match CUDA behavior on every accelerator backend), found
while diagnosing a 35B MoE (Qwen3.6-35B-A3B, qwen3_5_moe_text) boot hang on
Intel Arc Pro B70 XPU. That hang was ultimately root-caused to
--enable-sleep-mode's XpuMemAllocator exhausting Level Zero physical-memory
handles on this MoE's ~123k expert tensors (error 40,
UR_RESULT_ERROR_OUT_OF_RESOURCES) -- see the 35B sleep-mode section of
kubernetes/llm/components/llama-swap/README.md -- and is unrelated to this
fix. This sync fix is kept on its own merits: it is a real bug independent
of that investigation, costs nothing, and is a strict correctness
improvement (matches CUDA behavior on XPU).

Idempotent (QWEN_TRITON_WARMUP_XPU marker).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

MARKER = "# QWEN_TRITON_WARMUP_XPU"

OLD_SYNC = '''def _synchronize_device(device: torch.device) -> None:
    if device.type == "cuda":
        torch.accelerator.synchronize(device)'''

NEW_SYNC = '''def _synchronize_device(device: torch.device) -> None:
    # QWEN_TRITON_WARMUP_XPU: CUDA-only guard silently no-op'd on XPU,
    # letting the warmup return before the Triton kernels it just launched
    # actually complete. See module docstring.
    if device.type in ("cuda", "xpu"):
        torch.accelerator.synchronize(device)'''


def patch_text(text: str) -> str:
    if MARKER in text:
        return text

    # Add module docstring marker right after the module docstring so
    # idempotency checks are trivial and greppable.
    text = text.replace(
        '"""Warm up Qwen Triton kernels from the loaded model\'s compile keys."""',
        '"""Warm up Qwen Triton kernels from the loaded model\'s compile keys."""\n'
        f'{MARKER}',
        1,
    )

    if text.count(OLD_SYNC) != 1:
        raise RuntimeError(
            f"_synchronize_device anchor not found uniquely "
            f"(occurrences: {text.count(OLD_SYNC)}); refusing to patch"
        )
    text = text.replace(OLD_SYNC, NEW_SYNC, 1)

    return text


def main() -> None:
    spec = importlib.util.find_spec("vllm")
    if spec is None or not spec.submodule_search_locations:
        raise SystemExit("vllm package not found")
    path = (
        Path(next(iter(spec.submodule_search_locations)))
        / "model_executor"
        / "warmup"
        / "qwen_triton_warmup.py"
    )
    original = path.read_text()
    patched = patch_text(original)
    if patched == original:
        print(f"already patched {path}")
        return
    compile(patched, str(path), "exec")
    path.write_text(patched)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
