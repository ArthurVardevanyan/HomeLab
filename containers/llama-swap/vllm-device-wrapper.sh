#!/usr/bin/env bash
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
if [[ -n "${SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS+x}" ]]; then
  export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS
fi
if [[ -n "${ZE_AFFINITY_MASK+x}" ]]; then
  export ZE_AFFINITY_MASK
fi

# Tee stdout/stderr to a PVC-logged file so the next stall is diagnosable
# (previously lost with the old pod; see the Mode 2 investigation).
# Pipe to tee preserves the stream that llama-swap parses as JSON, while
# writing a human-readable log for the operator. Size-rotate at 100 MiB,
# keep 3 copies.
set -o pipefail

LOG_DIR=/data/logs
LOG_FILE="${LOG_DIR}/vllm-${1##*/}.log"
mkdir -p "${LOG_DIR}"

# Simple size-based rotation (3 files × 100 MiB max)
rotate_logs() {
  if [[ -f "${LOG_FILE}" ]]; then
    local size
    size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
    if [[ ${size} -gt 104857600 ]]; then
      [[ -f "${LOG_FILE}.2" ]] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
      [[ -f "${LOG_FILE}.1" ]] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"
      mv "${LOG_FILE}" "${LOG_FILE}.1"
    fi
  fi
}

rotate_logs
exec /opt/venv/bin/vllm serve "$@" 2>&1 | tee -a "${LOG_FILE}"
