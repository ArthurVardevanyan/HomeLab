#!/bin/sh
# Wrapper script for launching llama.cpp (llama-server) under llama-swap.
#
# Why this exists: this image's default LD_LIBRARY_PATH puts /opt/venv/lib
# first so vLLM's SYCL 9 stack resolves urDeviceWaitExp (see containerfile).
# llama-server was built by IntelLLVM against oneAPI 2025.3; if it inherits
# that vLLM-first LD_LIBRARY_PATH it binds the venv's OpenMP/Intel runtime
# instead of its own (libiomp5/libimf/libsvml/libintlc/libirng all differ by
# md5 between the two). That ABI mismatch segfaults llama-server on CPU
# (-ngl 0, immediately after "llama threadpool init") and hangs it on GPU
# (-ngl 99, host-side stall mid-layer-0 attention with VRAM allocated but
# the GPU idle). See the /app/rt COPY block in the containerfile for the
# full writeup and the vendored library list.
#
# Fix: override LD_LIBRARY_PATH to the hermetic /app/rt runtime vendored at
# build time, so llama-server always uses the Intel runtime it was built
# against, never vLLM's. This must be an unconditional override (not a
# guarded append like vllm-device-wrapper.sh does for its vars) because the
# whole point is to replace the inherited vLLM-first path, not extend it.
#
# ONEAPI_DEVICE_SELECTOR (unlike with vLLM/torch XPU) DOES work for
# llama.cpp/SYCL device enumeration and is set per-model in llama-swap.yaml
# env: blocks — left untouched here, only LD_LIBRARY_PATH is overridden.
export LD_LIBRARY_PATH=/app/rt:/app

exec /app/llama-server "$@"
