#!/bin/sh
# Wrapper script to ensure ONEAPI env vars are exported before vLLM.
# This is required because Python multiprocessing 'spawn' method (default
# on Linux) does not inherit environment variables from the parent process
# to child processes (e.g. EngineCore subprocesses).
#
# By exporting the vars here and exec-ing vLLM, we guarantee that all
# child processes inherit the XPU device selection configuration.

export ONEAPI_DEVICE_SELECTOR="${ONEAPI_DEVICE_SELECTOR}"
export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS="${SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS}"
export ZE_AFFINITY_MASK="${ZE_AFFINITY_MASK}"

exec /opt/venv/bin/vllm serve "$@"
