# Local LLM

GPU-backed local LLM serving for the homelab. The **default (`overlays/okd`)
backend is llama.cpp (Vulkan)** running on the Intel Arc Pro B70.

## Table of Contents

- [Local LLM](#local-llm)
  - [Table of Contents](#table-of-contents)
  - [Backends / Overlays](#backends--overlays)
  - [Default: llama.cpp Vulkan on the Intel Arc B70](#default-llamacpp-vulkan-on-the-intel-arc-b70)
    - [Model](#model)
    - [B70 tuning rationale](#b70-tuning-rationale)
    - [Mesa 26.1 (biggest perf lever) — handled in the image](#mesa-261-biggest-perf-lever--handled-in-the-image)
  - [GPU Monitoring (nvidia-smi equivalents)](#gpu-monitoring-nvidia-smi-equivalents)
  - [Performance: why decode may trail bare-metal benchmarks](#performance-why-decode-may-trail-bare-metal-benchmarks)
  - [Scaling](#scaling)
  - [Layout](#layout)
  - [REF](#ref)

## Backends / Overlays

| Overlay        | Backend                        | Hardware      | Notes                                      |
| -------------- | ------------------------------ | ------------- | ------------------------------------------ |
| `overlays/okd` | **llama.cpp Vulkan** (default) | Intel Arc B70 | Qwen3.6-35B-A3B, tracks mainline llama.cpp |

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
- `--sleep-idle-seconds 28800` — the resident model (incl. KV cache) is
  **unloaded from VRAM after 8 hour idle** and auto-reloads on the next
  request. No manual VRAM management needed.

Global B70 tuning (in `[*]` of the preset): `n-gpu-layers 999`, `flash-attn on`,
`cache-type-k/v f16`, `ubatch-size 2048`, `ctx-size 131072`,
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
- `-c 131072` — 128K context (model natively supports 256K; hybrid DeltaNet attention keeps the KV cache small enough for 128K on a single 32GB card at f16).
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
oc -n llm scale deployment/llm-server --replicas=1
oc -n llm logs deploy/llm-server | grep -i "matrix cores"
```

Notes:

- Do **not** rely solely on llama.cpp's `matrix cores:` device line to confirm
  the fast path — recent builds report `KHR_coopmat` on hardware that
  previously reported `NV_coopmat2` at identical throughput. Verify with actual
  decode t/s (target ~76 t/s single-stream on Qwen3.6-35B-A3B).

## GPU Monitoring (nvidia-smi equivalents)

Live Intel GPU telemetry tools are packaged in a **separate** image
(`containers/intel-gpu-monitor/`) deployed as a scaled-0 helper in the `llm`
namespace (`kubernetes/intel-gpu-monitor/`). Scale it up on demand — it requests
`gpu.intel.com/xe` so it sees `/dev/dri`:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm scale deployment/intel-gpu-monitor --replicas=1
POD=$(oc -n llm get pod -l app=intel-gpu-monitor -o name | head -1)

# Confirm the Vulkan ICD + cooperative-matrix support (the whole point):
oc -n llm exec "$POD" -- sh -c 'vulkaninfo | grep -iE "deviceName|cooperativeMatrix"'

# Live utilization / VRAM / power / temp / freq (the nvidia-smi analog):
oc -n llm exec "$POD" -- xpu-smi discovery
oc -n llm exec "$POD" -- xpu-smi stats -d 0
oc -n llm exec "$POD" -- xpu-smi dump -d 0 -m 0,1,2,3,5

# Best-effort engine busy% (limited without CAP_PERFMON):
oc -n llm exec "$POD" -- intel_gpu_top -l

# OpenCL / VA-API sanity:
oc -n llm exec "$POD" -- clinfo | grep -i "Device Name"

# Scale back down when done (frees the GPU share):
oc -n llm scale deployment/intel-gpu-monitor --replicas=0
```

Workload-level metrics (llama.cpp exposes Prometheus metrics via `--metrics`):

```bash
POD=$(oc -n llm get pod -l app=llm-server -o name | head -1)
oc -n llm exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/metrics | head'
oc -n llm exec "$POD" -- sh -c 'wget -qO- http://localhost:11434/v1/models'
```

Kubernetes capacity view (device-plugin advertised resource):

```bash
oc get node gpu-1 -o jsonpath='{.status.allocatable.gpu\.intel\.com/xe}{"\n"}'
```

## Performance: why decode may trail bare-metal benchmarks

Published B70 benchmarks (bare-metal Arch/Manjaro) report ~1,824 t/s prefill and
~76 t/s single-stream decode on Qwen3.6-35B-A3B. On this cluster, **prefill
matches** (~1,830 t/s → Mesa 26.1 coopmat path confirmed working) but **decode
can trail** (~30 t/s under contention). Prefill is compute-bound and saturates
regardless; decode is latency/bandwidth-bound and exposes differences the
benchmark setup does not have:

1. **Parallel slots (in our control).** Multiple llama.cpp slots split KV and
   contend for memory bandwidth, cutting per-stream decode. The router preset
   sets `parallel = 1` so a single request gets the whole GPU + full 128K ctx.
   The bare-metal 76 t/s is an isolated single-stream number — compare only
   against an uncontended request.
2. **Host `xe` KMD + GPU power/clock state (NOT in our control from the pod).**
   The kernel driver, firmware, and clock/power governor live on the RHCOS
   host, not the container. An older host `xe` driver, or the card clocking down
   between bandwidth-bound decode steps (PL1/thermal/residency), hits decode far
   harder than prefill. This is the fundamental bare-metal-vs-OpenShift gap.

### Decisive diagnostics

Run after setting `parallel = 1` and restarting the pod. First, an uncontended
single-stream number:

```bash
oc -n llm rollout restart deploy/llm-server   # reload the preset
POD=$(oc -n llm get pod -l app=llm-server -o name | head -1)
# one quiet request, then read tg (tokens/sec) — no other traffic:
oc -n llm logs "$POD" | grep -E "tg =|n_parallel|n_ctx_per_seq"
```

Confirm full GPU offload + coopmat path (rules out CPU spill):

```bash
oc -n llm logs "$POD" | grep -iE "matrix cores|offloaded|CPU buffer|VRAM|not enough|n_gpu_layers"
```

Check GPU clocks UNDER decode load (the throttle hypothesis) via the monitor
pod — if freq sits well below the ~2.4 GHz boost while decoding, the host is
clock/power-limiting:

```bash
oc -n llm scale deploy/intel-gpu-monitor --replicas=1
MON=$(oc -n llm get pod -l app=intel-gpu-monitor -o name | head -1)
oc -n llm exec "$MON" -- xpu-smi stats -d 0     # freq, power, util, temp
oc -n llm exec "$MON" -- sh -c 'cat /sys/class/drm/card*/gt/gt0/rps_*_freq_mhz'
oc -n llm scale deploy/intel-gpu-monitor --replicas=0
```

Interpretation:

- **Uncontended decode ~50–76 t/s** → the gap was slot contention; done.
- **Still ~30–40 t/s AND clocks are high, no CPU spill** → likely host `xe`
  driver maturity / coopmat variant; a container-side fix won't help much.
- **Clocks low under load** → host power/thermal/governor throttling (RHCOS
  node-level), outside this app's control.

## Scaling

Scaled to `0` by default to free the GPU. Scale up to load the model
(first start downloads ~22 GB):

```bash
oc -n llm scale deployment/llm-server --replicas=1
oc -n llm logs -f deployment/llm-server   # watch model load + Vulkan device
```

## Layout

- `base/` — llama.cpp Vulkan Deployment + namespace, RBAC, network policies,
  PVC, service.
- `overlays/okd/` — default; base + HuggingFace egress firewall.

## REF

- <https://github.com/ggml-org/llama.cpp>
- <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF>
