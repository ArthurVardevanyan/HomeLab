#!/bin/sh
# Wrapper script for launching vLLM under llama-swap.
#
# NOTE: Python multiprocessing 'spawn' (the default on Linux) DOES inherit
# the parent process's environment into child processes, so this script is
# not needed for env propagation to EngineCore subprocesses. It exists as a
# single place to normalize/guard the XPU device-selection vars before
# exec-ing vLLM.
#
# ZE_AFFINITY_MASK is the only var here that actually filters XPU devices:
# vLLM's XPUPlatform.device_control_env_var == "ZE_AFFINITY_MASK", and torch
# ignores ONEAPI_DEVICE_SELECTOR entirely for XPU device enumeration
# (verified: torch.xpu.device_count() is unchanged across every selector
# value). Do not add ONEAPI_DEVICE_SELECTOR back here for vLLM models.
#
# Guard each export with ${VAR+...} so an unset var stays unset rather than
# being coerced to an empty string. An empty ZE_AFFINITY_MASK is NOT
# equivalent to unset: vLLM's device_control_env_var check treats an empty
# string as "unset" (see vllm/platforms/interface.py), but exporting an
# empty value here would still shadow any broader ZE_AFFINITY_MASK set at
# the container level, which is a behavior change we don't want to hide.
if [ -n "${SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS+x}" ]; then
  export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS
fi
if [ -n "${ZE_AFFINITY_MASK+x}" ]; then
  export ZE_AFFINITY_MASK
fi

exec /opt/venv/bin/vllm serve "$@"
