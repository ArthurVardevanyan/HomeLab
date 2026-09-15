#!/usr/bin/env python3
"""Patch XPU xpu_mem_allocator to fix expandable-segments leak in sleep mode.

Expandable segments are incompatible with the pluggable allocator used for
sleep mode (pytorch#147851). When enabled via PYTORCH_ALLOC_CONF, the XPU
allocator uses the VMM/remap path and bypasses the pluggable-allocator
malloc callback, leaving pointer_to_data empty so sleep() frees 0 GiB.

This patch mirrors CUDA's cumem.py:79-141: temporarily disable expandable
segments around each pool context, and release freed-but-unmapped allocations
via the pool snapshot (pytorch#145168).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

MARKER = "# XPU_SLEEP_EXPANDABLE_SEGMENTS"

# ---------- import block: add 'import os' after 'import gc' ----------

OLD_IMPORTS = "import gc\n"
NEW_IMPORTS = "import gc\nimport os\n"


# ---------- XpuMemAllocator.use_memory_pool ----------

OLD = '''    def use_memory_pool(self, tag: str | None = None):
        if tag is None:
            tag = XpuMemAllocator.default_tag

        old_tag = self.current_tag
        self.current_tag = tag
        try:
            with use_memory_pool_with_allocator(
                self.python_malloc_callback,
                self.python_free_callback,
            ) as data:
                self.allocator_and_pools[tag] = data
                yield
        finally:
            self.current_tag = old_tag'''

NEW = '''    def use_memory_pool(self, tag: str | None = None):
        if tag is None:
            tag = XpuMemAllocator.default_tag

        # XPU_SLEEP_EXPANDABLE_SEGMENTS: expandable segments are incompatible
        # with the pluggable-allocator memory pool used for sleep mode
        # (pytorch#147851).  If the user has enabled them via
        # PYTORCH_ALLOC_CONF / PYTORCH_XPU_ALLOC_CONF, temporarily disable
        # them for the duration of the pool context and restore on exit.
        # Otherwise pool allocations bypass the malloc callback,
        # pointer_to_data stays empty, and sleep() frees 0 GiB.
        conf = os.environ.get("PYTORCH_ALLOC_CONF", "")
        conf += os.environ.get("PYTORCH_XPU_ALLOC_CONF", "")
        expandable_was_enabled = "expandable_segments:True" in conf
        if expandable_was_enabled:
            torch._C._accelerator_setAllocatorSettings(
                "expandable_segments:False",
            )

        old_tag = self.current_tag
        self.current_tag = tag
        try:
            with use_memory_pool_with_allocator(
                self.python_malloc_callback,
                self.python_free_callback,
            ) as data:
                self.allocator_and_pools[tag] = data
                yield
                # Release pool allocations that were freed but not yet unmapped
                # (pytorch#145168: pluggable-allocator empty_cache bug).
                for _alloc in data[0].snapshot():
                    size = _alloc.get("allocated_size")
                    addr = _alloc.get("address")
                    if size == 0 and addr is not None:
                        handle = self._python_free_callback(addr)
                        unmap_and_release(handle)
        finally:
            self.current_tag = old_tag
            if expandable_was_enabled:
                torch._C._accelerator_setAllocatorSettings(
                    "expandable_segments:True",
                )'''


def patch_text(text: str) -> str:
    if MARKER in text:
        return text

    # Add 'import os' (idempotent, only the gc line appears once)
    if NEW_IMPORTS not in text:
        text = text.replace(OLD_IMPORTS, NEW_IMPORTS, 1)

    # Patch use_memory_pool
    if text.count(OLD) != 1:
        raise RuntimeError(
            f"use_memory_pool anchor not found uniquely "
            f"(occurrences: {text.count(OLD)}); refusing to patch"
        )
    text = text.replace(OLD, NEW, 1)
    return text


def main() -> None:
    spec = importlib.util.find_spec("vllm")
    if spec is None or not spec.submodule_search_locations:
        raise SystemExit("vllm package not found")
    path = (
        Path(next(iter(spec.submodule_search_locations)))
        / "device_allocator"
        / "xpumem.py"
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
