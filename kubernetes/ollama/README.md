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
  - [Mesa 26.1 (biggest perf lever) — handled in the image](#mesa-261-biggest-perf-lever--handled-in-the-image)
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

Served via **llama-server router mode** — a single process hosts both models
(preset `base/configmap.yaml` → `models.ini`), pre-downloaded to the PVC by an
init container. Select the model by name in the client's `model` field:

| Model id          | Model                        | Trait                    |
| ----------------- | ---------------------------- | ------------------------ |
| `qwen3.6-35b-a3b` | Qwen3.6-35B-A3B (sparse MoE) | ~4x faster decode on B70 |
| `qwen3.6-27b`     | Qwen3.6-27B (dense)          | higher quality, slower   |

Both are reached on the one endpoint (`:11434`). Router behavior:

- `--models-max 1` — only **one** model resident in VRAM at a time; requesting
  the other evicts the current one (both cannot fit in 32 GB: ~22 GB MoE +
  ~17 GB dense).
- `--sleep-idle-seconds 900` — the resident model (incl. KV cache) is
  **unloaded from VRAM after 15 min idle** and auto-reloads on the next
  request. No manual VRAM management needed.

Global B70 tuning (in `[*]` of the preset): `n-gpu-layers 999`, `flash-attn on`,
`cache-type-k/v f16`, `ubatch-size 2048`, `ctx-size 65536`,
`reasoning-format none`.

> **Probes:** `livenessProbe`/`startupProbe` hit `GET /models` (router-level,
> stays HTTP 200 during a model load/swap), while `readinessProbe` hits
> `GET /health` (returns 503 while a model loads, keeping the pod out of the
> Service until ready). Do **not** put liveness on `/health` — it flaps 503
> during swaps and would kill the container mid-load.

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

### Mesa 26.1 (biggest perf lever) — handled in the image

The single biggest throughput lever on the B70 is **not** the inference engine
— it is the **Mesa Vulkan driver**. Mesa 26.1 enabled a cooperative-matrix
path for Intel ANV that roughly **doubles** Vulkan decode throughput on
Battlemage.

Crucially, the Vulkan userspace (loader, `intel_icd.json`, `libvulkan_intel.so`,
Mesa) lives **inside the container**, not on the RHCOS host. The upstream
`ghcr.io/ggml-org/llama.cpp:server-vulkan` image ships Mesa 26.0.3 (too old), so
this app runs a **custom image** (`containers/llama-cpp-vulkan/`) that upgrades
Mesa to >= 26.1 via the kisak-mesa PPA. No node/RHCOS change is required.

Confirm the fast path is active from inside the pod (or the monitor pod):

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n ollama scale deployment/ollama-coder --replicas=1
oc -n ollama logs deploy/ollama-coder | grep -i "matrix cores"
```

Notes:

- Do **not** rely solely on llama.cpp's `matrix cores:` device line to confirm
  the fast path — recent builds report `KHR_coopmat` on hardware that
  previously reported `NV_coopmat2` at identical throughput. Verify with actual
  decode t/s (target ~76 t/s single-stream on Qwen3.6-35B-A3B).

## GPU Monitoring (nvidia-smi equivalents)

Live Intel GPU telemetry tools are packaged in a **separate** image
(`containers/intel-gpu-monitor/`) deployed as a scaled-0 helper in the `ollama`
namespace (`kubernetes/intel-gpu-monitor/`). Scale it up on demand — it requests
`gpu.intel.com/xe` so it sees `/dev/dri`:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n ollama scale deployment/intel-gpu-monitor --replicas=1
POD=$(oc -n ollama get pod -l app=intel-gpu-monitor -o name | head -1)

# Confirm the Vulkan ICD + cooperative-matrix support (the whole point):
oc -n ollama exec "$POD" -- sh -c 'vulkaninfo | grep -iE "deviceName|cooperativeMatrix"'

# Live utilization / VRAM / power / temp / freq (the nvidia-smi analog):
oc -n ollama exec "$POD" -- xpu-smi discovery
oc -n ollama exec "$POD" -- xpu-smi stats -d 0
oc -n ollama exec "$POD" -- xpu-smi dump -d 0 -m 0,1,2,3,5

# Best-effort engine busy% (limited without CAP_PERFMON):
oc -n ollama exec "$POD" -- intel_gpu_top -l

# OpenCL / VA-API sanity:
oc -n ollama exec "$POD" -- clinfo | grep -i "Device Name"

# Scale back down when done (frees the GPU share):
oc -n ollama scale deployment/intel-gpu-monitor --replicas=0
```

Workload-level metrics (llama.cpp exposes Prometheus metrics via `--metrics`):

```bash
POD=$(oc -n ollama get pod -l app=ollama-coder -o name | head -1)
oc -n ollama exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/metrics | head'
oc -n ollama exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/v1/models'
```

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
