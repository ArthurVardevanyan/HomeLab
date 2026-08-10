# Local LLM (ollama app)

GPU-backed local LLM serving for the homelab. Despite the app name, the
**default (`overlays/okd`) backend is now llama.cpp (Vulkan)** running on the
Intel Arc Pro B70 — not ollama. Ollama variants are preserved as swappable,
dormant Kustomize components.

## Table of Contents

- [Backends / Overlays](#backends--overlays)
- [Default: llama.cpp Vulkan on the Intel Arc B70](#default-llamacpp-vulkan-on-the-intel-arc-b70)
  - [Model](#model)
  - [B70 tuning rationale](#b70-tuning-rationale)
  - [Mesa prerequisite (biggest perf lever)](#mesa-prerequisite-biggest-perf-lever)
- [GPU Monitoring (nvidia-smi equivalents)](#gpu-monitoring-nvidia-smi-equivalents)
- [Scaling](#scaling)
- [Layout](#layout)
- [REF](#ref)

## Backends / Overlays

| Overlay               | Backend                        | Hardware        | Notes                                      |
| --------------------- | ------------------------------ | --------------- | ------------------------------------------ |
| `overlays/okd`        | **llama.cpp Vulkan** (default) | Intel Arc B70   | Qwen3.6-35B-A3B, tracks mainline llama.cpp |
| `overlays/okd-nvidia` | ollama (CUDA)                  | NVIDIA GPU node | Multi-model (qwen3.6, gemma4)              |

Dormant components (not wired to any overlay, kept for fallback / A-B tests):

| Component                | Backend                      | Why kept                                       |
| ------------------------ | ---------------------------- | ---------------------------------------------- |
| `components/nvidia`      | ollama CUDA                  | Enabled by `okd-nvidia`                        |
| `components/ipex-ollama` | Intel IPEX-LLM ollama (SYCL) | Fallback; older fork, cannot run newest models |

The base Deployment / Service / PVC intentionally keep the `ollama-coder`
names so the LoadBalancer IP (`10.101.10.246:11434`), NetworkPolicies, and
client config remain stable across backend swaps.

## Default: llama.cpp Vulkan on the Intel Arc B70

### Model

`unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` (~22 GB), auto-downloaded by
llama.cpp's `-hf` flag into the PVC (`LLAMA_CACHE=/.ollama/cache`) and served
under the alias `qwen3.6-35b-a3b` on the OpenAI-compatible API at `:11434`.

The **sparse MoE (35B, ~3B active)** is chosen deliberately over the dense
27B: the B70 is memory-bandwidth-bound (608 GB/s), and dense decode reads all
27 GB/token vs the MoE's ~3 GB/token — roughly 4x faster decode for the MoE on
this hardware.

> **VRAM note:** ~22 GB weights + `f16` KV at 64K on a 35B MoE is tight on the
> 32 GB card. If llama-server logs show an out-of-memory / device-allocation
> failure, drop `--cache-type-k/v` to `q8_0` or lower `-c`.

### B70 tuning rationale

Args in `base/deployment.yaml`, informed by B70 llama.cpp benchmarking:

- `--ubatch-size 2048` — larger physical batch is a big prefill win on
  Battlemage (opposite of the well-known AMD "smaller ubatch" advice).
- `--cache-type-k/v f16` — f16 KV holds decode speed far better than `q4_0`
  past ~16K context on this hardware.
- `-c 65536` — 64K context.
- `--reasoning-format none` — reasoning off server-side; clients opt in
  per-request.
- Flash attention on, all layers offloaded (`-ngl 999`).

### Mesa prerequisite (biggest perf lever)

The single biggest throughput lever on the B70 is **not** the inference
engine — it is the host **Mesa Vulkan driver**. Mesa 26.1 enabled a
cooperative-matrix path for Intel ANV that roughly **doubles** Vulkan decode
throughput. This lives on the RHCOS/OKD **node**, not in the container.

Verify on the GPU node before expecting full performance:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc debug node/gpu-1 -- chroot /host sh -c '
  rpm -q mesa-vulkan-drivers 2>/dev/null || true
  vulkaninfo 2>/dev/null | grep -iE "driverName|driverInfo|coopmat" | head
'
```

Notes:

- Aim for **Mesa >= 26.1**. If RHCOS ships an older Mesa, decode is roughly
  half speed; upgrading RHCOS userspace Mesa is a separate node-level effort.
- Do **not** rely on llama.cpp's `matrix cores:` device line to confirm the
  fast path — recent builds report `KHR_coopmat` on hardware that previously
  reported `NV_coopmat2` at identical throughput.

## GPU Monitoring (nvidia-smi equivalents)

Intel GPUs do not use `nvidia-smi`. Equivalents:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n ollama scale deployment/ollama-coder --replicas=1
POD=$(oc -n ollama get pod -l app=ollama-coder -o name | head -1)
```

From the host / a node debug shell:

```bash
oc debug node/gpu-1
chroot /host
# Live per-engine utilization / power / freq (closest to nvtop):
intel_gpu_top
# Driver binding + device nodes:
lspci -nnk | grep -iA3 '8086'
ls -l /dev/dri/
# Sysfs frequency:
cat /sys/class/drm/card*/gt/gt0/rps_cur_freq_mhz 2>/dev/null
```

Workload-level (llama.cpp exposes Prometheus metrics via `--metrics`):

```bash
oc -n ollama exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/metrics | head'
oc -n ollama exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/v1/models'
```

If using the `ipex-ollama` component instead, that image also bundles
`xpu-smi` (the direct `nvidia-smi` analog) and `sycl-ls`.

Kubernetes capacity view (device-plugin advertised resource):

```bash
oc get node gpu-1 -o jsonpath='{.status.allocatable.gpu\.intel\.com/xe}{"\n"}'
```

## Scaling

Scaled to `0` by default to free the GPU. Scale up to load the model
(first start downloads ~22 GB):

```bash
oc -n ollama scale deployment/ollama-coder --replicas=1
oc -n ollama logs -f deployment/ollama-coder   # watch model load + Vulkan device
```

## Layout

- `base/` — llama.cpp Vulkan Deployment + namespace, RBAC, network policies,
  PVC, service.
- `components/nvidia/` — full `$patch: replace` to the NVIDIA ollama backend.
- `components/ipex-ollama/` — full `$patch: replace` to the Intel IPEX ollama
  backend (fallback).
- `overlays/okd/` — default; base + HuggingFace egress firewall.
- `overlays/okd-nvidia/` — base + `nvidia` component + ollama-registry egress.

## REF

- <https://github.com/ggml-org/llama.cpp>
- <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF>
- <https://github.com/ollama/ollama>
