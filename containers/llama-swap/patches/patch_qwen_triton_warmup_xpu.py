#!/usr/bin/env python3
"""Fix Qwen GDN Triton warmup hang on XPU (qwen3_5_moe / qwen3_5_moe_text).

Two related bugs in ``qwen_triton_warmup.py``, both CUDA-only code paths that
silently no-op on XPU instead of raising:

1. ``_synchronize_device`` only synchronizes when ``device.type == "cuda"``:

       def _synchronize_device(device: torch.device) -> None:
           if device.type == "cuda":
               torch.accelerator.synchronize(device)

   On XPU this is a no-op, so the warmup call site never waits for the
   dummy-input Triton kernels it just launched.

2. The GDN (gated delta-net / linear-attention) warmup kernels
   (``_warm_causal_conv1d_fwd_kernel``, ``_warm_fused_post_conv_kernel``,
   ``_warm_fused_sigmoid_gating_delta_rule_update_kernel``) are unconditional
   for any model whose ``model_type`` is in ``_QWEN_MODEL_TYPES`` (includes
   ``qwen3_5_moe`` / ``qwen3_5_moe_text``) -- there is no XPU gate at all.

Observed on Intel Arc Pro B70: booting Qwen3.6-35B-A3B (qwen3_5_moe_text,
layer_types include "linear_attention") with --enforce-eager reaches

    JIT kernel warmup finished in 0.00s.
    Warming up Qwen Triton kernels for model_type=qwen3_5_moe_text.

and then hangs indefinitely. Process state confirms a live spin, not a
crash or a compile: one thread pegged at ~90% CPU, ~88% of which is system
time (not growing Triton JIT/cache activity), wchan=0 (not blocked on a
syscall). This is consistent with the fused_sigmoid_gating_delta_rule_update
Level Zero kernel launch racing ahead of a synchronize that never happens
(bug 1), compounded by no XPU validation of these GDN kernels at all
(bug 2; contrast with the existing patch_gdn_mixed_split_v5.py, which had to
work around a separate XPU GDN bug in the runtime attention path).

This patch:
  (A) fixes _synchronize_device to also synchronize on "xpu" -- a strict
      correctness fix, matches CUDA behavior, always applied.
  (B) adds an opt-in escape hatch, gated by the VLLM_SKIP_QWEN_GDN_WARMUP=1
      environment variable, to skip the GDN warmup kernels on XPU entirely
      if (A) alone is not sufficient to unblock boot. Defaults to unset
      (warmup still runs) so this patch is a no-op change in behavior
      unless the env var is explicitly set at runtime -- no rebuild needed
      to toggle it.

Idempotent (QWEN_TRITON_WARMUP_XPU marker).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

MARKER = "# QWEN_TRITON_WARMUP_XPU"

# ---------- import block: add 'import os' after 'import torch' ----------

OLD_IMPORTS = "import torch\n\nfrom vllm.logger import init_logger"
NEW_IMPORTS = "import os\nimport torch\n\nfrom vllm.logger import init_logger"


# ---------- (A) _synchronize_device: sync on xpu too ----------

OLD_SYNC = '''def _synchronize_device(device: torch.device) -> None:
    if device.type == "cuda":
        torch.accelerator.synchronize(device)'''

NEW_SYNC = '''def _synchronize_device(device: torch.device) -> None:
    # QWEN_TRITON_WARMUP_XPU: CUDA-only guard silently no-op'd on XPU,
    # letting the warmup return before the Triton kernels it just launched
    # actually complete. See module docstring.
    if device.type in ("cuda", "xpu"):
        torch.accelerator.synchronize(device)'''


# ---------- (B) opt-in skip of GDN warmup on XPU ----------

OLD_GATE = '''    device = getattr(runner, "device", torch.device("cuda"))
    logger.info("Warming up Qwen Triton kernels for model_type=%s.", model_type)'''

NEW_GATE = '''    device = getattr(runner, "device", torch.device("cuda"))

    # QWEN_TRITON_WARMUP_XPU: opt-in escape hatch. The GDN warmup kernels
    # below have no XPU validation upstream and have been observed to hang
    # indefinitely on Intel Arc (Battlemage/Xe2) for qwen3_5_moe /
    # qwen3_5_moe_text models. Unset by default (warmup still runs); set
    # VLLM_SKIP_QWEN_GDN_WARMUP=1 to skip it if the synchronize fix above is
    # not sufficient on its own.
    if device.type == "xpu" and os.environ.get("VLLM_SKIP_QWEN_GDN_WARMUP", "0") == "1":
        logger.warning(
            "Skipping Qwen GDN Triton warmup on XPU for model_type=%s "
            "(VLLM_SKIP_QWEN_GDN_WARMUP=1).",
            model_type,
        )
        return

    logger.info("Warming up Qwen Triton kernels for model_type=%s.", model_type)'''


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

    # Add 'import os' (idempotent, only this exact block appears once)
    if NEW_IMPORTS not in text:
        if text.count(OLD_IMPORTS) != 1:
            raise RuntimeError(
                f"import anchor not found uniquely "
                f"(occurrences: {text.count(OLD_IMPORTS)}); refusing to patch"
            )
        text = text.replace(OLD_IMPORTS, NEW_IMPORTS, 1)

    # (A) _synchronize_device
    if text.count(OLD_SYNC) != 1:
        raise RuntimeError(
            f"_synchronize_device anchor not found uniquely "
            f"(occurrences: {text.count(OLD_SYNC)}); refusing to patch"
        )
    text = text.replace(OLD_SYNC, NEW_SYNC, 1)

    # (B) opt-in skip gate
    if text.count(OLD_GATE) != 1:
        raise RuntimeError(
            f"warmup gate anchor not found uniquely "
            f"(occurrences: {text.count(OLD_GATE)}); refusing to patch"
        )
    text = text.replace(OLD_GATE, NEW_GATE, 1)

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
