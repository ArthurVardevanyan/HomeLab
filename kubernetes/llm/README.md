# Local LLM

GPU-backed local LLM serving for the homelab. The **default (`overlays/okd`)
backend is llama-swap (Vulkan)** orchestrating llama-server processes on the
Intel Arc Pro B70 (2× GPUs, 64 GB VRAM pooled).

## Table of Contents

- [Local LLM](#local-llm)
  - [Table of Contents](#table-of-contents)
  - [Backends / Overlays](#backends--overlays)
  - [llama-swap with Vulkan on the Intel Arc Pro B70](#llama-swap-with-vulkan-on-the-intel-arc-pro-b70)
    - [Model Matrix](#model-matrix)
    - [B70 tuning rationale](#b70-tuning-rationale)
    - [KV cache: f16 vs q8\_0](#kv-cache-f16-vs-q8_0)
    - [Why not `--mlock` / `--ngl all`](#why-not---mlock----ngl-all)
    - [Mesa 26.1 (biggest perf lever) — handled in the image](#mesa-261-biggest-perf-lever--handled-in-the-image)
    - [Image tag](#image-tag)
  - [GPU Monitoring (nvidia-smi equivalents)](#gpu-monitoring-nvidia-smi-equivalents)
  - [Metrics](#metrics)
    - [Prometheus metric names](#prometheus-metric-names)
    - [Example PromQL queries](#example-promql-queries)
    - [TODO: Open WebUI metrics \& cluster OTEL](#todo-open-webui-metrics--cluster-otel)
  - [Performance: why decode may trail bare-metal benchmarks](#performance-why-decode-may-trail-bare-metal-benchmarks)
    - [Decisive diagnostics](#decisive-diagnostics)
  - [Scaling](#scaling)
  - [Layout](#layout)
  - [Open WebUI (chat front-end)](#open-webui-chat-front-end)
    - [Deployment](#deployment)
    - [OIDC / SSO](#oidc--sso)
    - [Database \& Websockets](#database--websockets)
    - [Storage](#storage)
    - [Document RAG](#document-rag)
      - [Why embeddings run on CPU (not the B70)](#why-embeddings-run-on-cpu-not-the-b70)
      - [RAG vs. web search](#rag-vs-web-search)
      - [Freshness / staleness](#freshness--staleness)
  - [Roadmap: connector auto-sync (Onyx)](#roadmap-connector-auto-sync-onyx)
  - [REF](#ref)

## Backends / Overlays

| Overlay        | Backend                           | Hardware               | Notes                                                 |
| -------------- | --------------------------------- | ---------------------- | ----------------------------------------------------- |
| `overlays/okd` | **llama-swap + Vulkan** (default) | Intel Arc Pro B70 (2×) | Qwen3.6 models, data-parallel + mixed workload matrix |

## llama-swap with Vulkan on the Intel Arc Pro B70

### Model Matrix

llama-swap orchestrates llama-server process lifecycles via a **config-driven
matrix** (`llama-swap.yaml`). Each model is launched as an independent
llama-server instance bound to one of the two GPUs (`GGML_VK_VISIBLE_DEVICES=0`
or `1`).

| Model id                          | Model                             | Trait                      | Vision                                       |
| --------------------------------- | --------------------------------- | -------------------------- | -------------------------------------------- |
| `35b-gpu0` / `35b-gpu1`           | Qwen3.6-35B-A3B (sparse MoE)      | ~4x faster decode on B70   | Yes                                          |
| `27b-gpu0` / `27b-gpu1`           | Qwen3.6-27B (dense)               | higher quality, slower     | Yes                                          |
| `coder30b-gpu0` / `coder30b-gpu1` | Qwen3-Coder-30B-A3B-Instruct-Q4_0 | Code-focused, high context | No (text-only; no mmproj published upstream) |

> **27B context limit:** The dense 27B model's `ctx-size` is set to `131072`
> (65K/slot at parallel=2) in the config, half the global 256K. The dense
> weights (~16.7 GB) + f16 KV cache + compute graph exceed the 32 GB VRAM at
> the full context, so this reduced budget keeps it under 32 GB while still
> providing ample context for most workloads. The 35B-A3B and coder models
> keep the full 256K.

llama-swap's **matrix** defines all valid VRAM combinations by pairing GPU 0
and GPU 1 models:

- **Data parallel** (same model duplicated on both cards): `dual_35b`,
  `dual_27b`, `dual_coder` — provides redundancy and doubles throughput for
  concurrent requests.
- **Mixed workloads** (different models side-by-side): `mix_1` through `mix_6`
  — e.g. `M35-0 & M27-1` loads 35B on GPU 0 and 27B on GPU 1.

Models with `ttl: 0` stay resident in VRAM 24/7. Real telemetry on gpu-1 shows
idle card power (6.8 W with model resident) is indistinguishable from idle with
no model (7.2 W), so unloading buys zero wattage.

> **Probes:** llama-swap health is `GET /` on port 8080 — returns HTTP 200 when
> the orchestrator is running (regardless of whether a llama-server process is
> loading). Do **not** put liveness on a llama-server-specific endpoint — it
> flaps during model swaps and would kill the container mid-load.

### B70 tuning rationale

Base args passed to each managed llama-server process (in `cmd_base` of
`llama-swap.yaml`), informed by B70 benchmarking:

- `--parallel 2` — two slots per llama-server instance for concurrent requests
  to the same model.
- `--cont-batching` — continuous batching for higher throughput.
- `--split-mode none` — no layer splitting across GPUs (each model runs on a
  single GPU).
- `--ubatch-size 2048` — larger physical batch is a big prefill win on
  Battlemage (opposite of the well-known AMD "smaller ubatch" advice).
- `--cache-type-k f16 --cache-type-v f16` — see [KV cache: f16 vs q8_0](#kv-cache-f16-vs-q8_0)
  below. Chosen over q8_0 because the B70 is **latency/compute-bound, not
  bandwidth-bound**, so the dequant-removal favors f16 at deep context.
- `--jinja` — Jinja template support for ChatML-style prompts.
- `--ctx-size 262144` — 256K total, split across 2 slots (~128K each). The model
  natively supports 256K; hybrid DeltaNet attention keeps the KV small enough
  that f16 only needs ~23 GB total (model + KV) on the 32 GB card.
- `--no-kv-unified` — static per-slot capacity; no shared/dynamic KV pool.
- `--reasoning-format auto` — reasoning format handled per-request by the client.
- `-ngl 99` — all layers offloaded to GPU.
- Flash attention on.

### KV cache: f16 vs q8_0

The B70 (measured on gpu-1) is **latency/compute-bound, not bandwidth-bound**:
under dual-slot load the GPU used only ~11% of its 608 GiB/s memory bandwidth.
The two KV types trade bandwidth for compute:

|                       | f16                 | q8_0                              |
| --------------------- | ------------------- | --------------------------------- |
| KV bytes/token        | 2x                  | ~1/2                              |
| Dequant compute/token | none                | extra ALU work                    |
| Deep-context prefill  | removes dequant tax | pays the compounding dequant cost |

Because the GPU has surplus bandwidth, q8_0's bandwidth saving is a **confirmed
wash** (no measurable bandwidth-% change vs f16) while its dequant cost is
concentrated exactly where the B70 hurts — **deep-context prefill** (prefill
near 128K is dominated by the fundamental O(n²) attention, plus a q8
dequant tax f16 removes). Decode speed is effectively identical either way
(the ~22 GB model-weight stream dwarfs the ~1–2 GB KV read). f16 is used
because the user routinely hits deep (50K–100K+) context, where f16's removal
of dequant overhead is the one real, visible win.

The fit at 256K f16 is **inferred from an observed ~23 GB** (model + KV) on the
32 GB card, not measured headroom. **Rollback:** if the pod OOMs on model load
or pushes VRAM over 32 GB, revert `cache-type-k`/`cache-type-v` to `q8_0`
(one-line change in `llama-swap.yaml`) — the f16 fit is a judgement call, not
a guarantee.

### Why not `--mlock` / `--ngl all`

- **`--mlock`** is intentionally NOT used. The model is fully GPU-resident
  (`-ngl 99`), so decode reads weights from GDDR6, not host RAM — mlock would
  pin ~22 GB of (capped, 64 GiB limit) host memory to protect pages that aren't
  on the decode path, risks OOM of the pod, and requires the `IPC_LOCK`
  capability the containers deliberately drop (`capabilities.drop: [ALL]`).
- **`--ngl all` is already covered** by `-ngl 99` in the base command.
  99 is the idiomatic "offload all layers" value; setting it in `cmd_base`
  prevents the silent CPU/MoE spill that tanks Battlemage decode. Confirm the
  `matrix cores` line / no `CPU buffer` offload in the pod log if decode is
  ever unexpectedly slow.

### Mesa 26.1 (biggest perf lever) — handled in the image

The single biggest throughput lever on the B70 is **not** the inference engine
— it is the **Mesa Vulkan driver**. Mesa 26.1 enabled a cooperative-matrix
path for Intel ANV that roughly **doubles** Vulkan decode throughput on
Battlemage.

The Vulkan userspace (loader, `intel_icd.json`, `libvulkan_intel.so`,
Mesa) lives **inside the container**, not on the RHCOS host. The upstream
llama-swap image ships an older Mesa, so this app runs a **custom image**
(`registry.arthurvardevanyan.com/homelab/llama-swap-vulkan`) that upgrades
Mesa to >= 26.1 via the kisak-mesa PPA. No node/RHCOS change is required.

### Image tag

The custom image is
`registry.arthurvardevanyan.com/homelab/llama-swap-vulkan:v249-b10380` — the tag
encodes the llama-swap version (`v249`) and the upstream llama.cpp build number
(`b10380`). Renovate-managed; when Renovate proposes a bump in the containerfile
it triggers a PaC build that pushes the new tag.

Confirm the fast path is active from inside the pod (or the monitor pod):

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm logs deploy/llama-swap | grep -i "matrix cores"
```

Notes:

- Do **not** rely solely on llama.cpp's `matrix cores:` device line to confirm
  the fast path — recent builds report `KHR_coopmat` on hardware that
  previously reported `NV_coopmat2` at identical throughput. Verify with actual
  decode t/s (target ~76 t/s single-stream on Qwen3.6-35B-A3B).

## GPU Monitoring (nvidia-smi equivalents)

Live Intel GPU telemetry tools are packaged in `containers/intel-gpu-monitor/`
and can be run on-demand with `oc debug` — no persistent deployment needed:

```bash
export KUBECONFIG=$HOME/.kube/okd

# On-demand debug pod with gpu.intel.com/xe request:
oc run intel-gpu-debug --image=registry.arthurvardevanyan.com/homelab/intel-gpu-monitor \
  -n llm --rm -i --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "debug",
      "image": "registry.arthurvardevanyan.com/homelab/intel-gpu-monitor:not_latest",
      "args": ["sleep", "300"],
      "resources": {
        "requests": {"gpu.intel.com/xe": "2"},
        "limits": {"gpu.intel.com/xe": "2"}
      },
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "dri",
        "mountPath": "/dev/dri"
      }]
    }],
    "volumes": [{
      "name": "dri",
      "hostPath": {
        "path": "/dev/dri"
      }
    }]
  }
}'

# Once inside the debug pod:
vulkaninfo | grep -iE "deviceName|cooperativeMatrix"
xpu-smi discovery
xpu-smi stats -d 0
xpu-smi dump -d 0 -m 0,1,2,3,5
intel_gpu_top -l
clinfo | grep -i "Device Name"
```

Workload-level metrics (llama-swap exposes Prometheus metrics via its
`/metrics` endpoint on port 8080):

```bash
oc -n llm exec deploy/llama-swap -- curl -sS "http://localhost:8080/metrics"
```

## Metrics

llama-swap exposes Prometheus metrics on `/metrics` (port 8080).

### Prometheus metric names

The llama-swap image defines these Prometheus scrape jobs (in
`kubernetes/prometheus/components/prometheus/config-map.yaml`):

```yaml
- job_name: "llama_swap"
  scrape_interval: 15s
  static_configs:
    - targets: ["llama-swap:8080"]
      labels:
        instance: llm
```

Key metric families (llama-swap only, no llama-server sub-scrapes):

| Metric family                   | Type    | Description                                              |
| ------------------------------- | ------- | -------------------------------------------------------- |
| `llamaswap_cpu_util_percent`    | Gauge   | CPU utilization per core (0–100)                         |
| `llamaswap_memory_total_bytes`  | Gauge   | Total system memory (bytes)                              |
| `llamaswap_memory_used_bytes`   | Gauge   | Used system memory (bytes)                               |
| `llamaswap_memory_free_bytes`   | Gauge   | Free system memory (bytes)                               |
| `llamaswap_swap_total_bytes`    | Gauge   | Total swap capacity (bytes)                              |
| `llamaswap_swap_used_bytes`     | Gauge   | Used swap (bytes)                                        |
| `llamaswap_load_average`        | Gauge   | Load average (labels: 1m, 5m, 15m)                       |
| `llamaswap_network_bytes_total` | Counter | Network bytes transferred (labels: interface, direction) |

llama-server (managed by llama-swap) exposes its own `/metrics` endpoint.
llama-swap's `/metrics` **already includes** the llama-server metrics under
namespaced prefixes. No separate `llama_server` scrape job is needed.

### Example PromQL queries

```promql
# Average CPU utilization across all cores
avg(llamaswap_cpu_util_percent)

# Memory usage percentage
llamaswap_memory_used_bytes / llamaswap_memory_total_bytes * 100

# Memory used vs free
llamaswap_memory_used_bytes
llamaswap_memory_free_bytes

# CPU utilization per core
llamaswap_cpu_util_percent

# Load average
llamaswap_load_average

# Network throughput (bytes/sec)
rate(llamaswap_network_bytes_total[5m])

# Total network bytes transferred
llamaswap_network_bytes_total
```

### TODO: Open WebUI metrics & cluster OTEL

- Open WebUI is not yet instrumented with a Prometheus metrics endpoint
  (see Open WebUI issue tracker for `prometheus_exporter` feature).
- Cluster-wide OTEL setup is planned. Until then, Grafana dashboards source
  metrics from Prometheus (llama-swap metrics only).

## Performance: why decode may trail bare-metal benchmarks

The B70 is a **PCIe Gen4 x8** GPU on the Pi 7 (PCIe Gen3 x4), and the
Dell R740 XL (PCIe Gen4 x16, but 8-lane slot). Neither matches the raw
bandwidth of a Gen5 x16 slot. Combined with the container Vulkan userspace,
you should expect **~60–70% of bare-metal desktop benchmarks** for single-stream
decode on Qwen3.6-35B-A3B (target ~76 t/s → expect 45–55 t/s).

### Decisive diagnostics

If decode drops below 40 t/s on Qwen3.6-35B-A3B, run this:

```bash
export KUBECONFIG=$HOME/.kube/okd

# 1. Confirm the cooperative matrix path is active:
oc -n llm exec deploy/llama-swap -- vulkaninfo | grep -iE "Device Name|cooperativeMatrix"
#   Expected: cooperativeMatrix types present (KHR_coopmat or NV_coopmat2)

# 2. Confirm the Vulkan userspace version:
oc -n llm exec deploy/llama-swap -- cat /usr/lib64/libvulkan_intel.so.1.0.0 ||   oc -n llm exec deploy/llama-swap -- vulkaninfo | grep -i mesa
#   Expected: Mesa >= 26.1

# 3. Confirm llama-server is using cooperative matrices at load:
oc -n llm logs deploy/llama-swap | grep -i "matrix"
#   Expected: "matrix cores" or "cooperative" in the load log

# 4. Check GPU memory pressure:
oc -n llm exec deploy/llama-swap -- xpu-smi dump -d 0 -m 0,1,2,3,5 | head -20
#   Expected: memory used < 32 GB for single model load

# 5. Verify the llama-swap pod itself is running:
oc -n llm exec deploy/llama-swap -- curl -sS http://localhost:8080/ | python3 -m json.tool
#   Expected: HTTP 200 with JSON status
```

If (1) fails (no cooperative matrix), the container has an old Mesa build.
If (2) fails (Mesa < 26.1), the image needs a rebuild.
If (3) fails (no cooperative matrix in llama-server load log), the llama-server
version may be too old.

## Scaling

For higher throughput:

- **Data parallel** (`dual_35b`, `dual_27b`, `dual_coder`): llama-swap runs
  the same model on both GPUs. Each slot gets a full 22 GB weight copy, but
  concurrent requests get full throughput on both cards.
- **Mixed workloads** (`mix_1`–`mix_6`): different models on each GPU for
  varied request profiles.
- **Multiple llama-swap replicas** with a LoadBalancer: add replicas in
  `overlays/okd/llama-swap.yaml` and expose via a LoadBalancer service.
  llama-swap's config matrix handles the shared hardware — no external
  orchestrator needed for GPU-aware scheduling.
- **Horizontal Pod Autoscaler** (HPA): not yet configured. With data parallel
  mode and ~2 slots per GPU, the current setup handles concurrent requests
  well. Add HPA once load patterns are measured.

## Layout

```text
kubernetes/llm/
├── base/
│   ├── llama-swap.yaml          # llama-swap Deployment + Service
│   └── llama-swap-configmap.yaml
├── components/
│   ├── llama-cpp-embed/         # CPU embeddings for Open WebUI (kept)
│   └── llama-swap/              # llama-swap component (config matrix, etc.)
├── overlays/
│   └── okd/
│       ├── kustomization.yaml   # includes llama-swap component
│       └── llama-swap.yaml      # GPU-specific overrides
├── config/
│   └── llama-swap.yaml          # llama-swap model matrix config (mounted as ConfigMap)
└── README.md                    # this file
```

## Open WebUI (chat front-end)

### Deployment

Open WebUI is deployed as a separate ArgoCD application in the `llm` namespace.
It connects to llama-swap via the backend URL (pointing to
`llama-swap:8080`).

### OIDC / SSO

Open WebUI uses the same Keycloak OIDC configuration as the rest of the cluster.
Configure the OIDC client in the Keycloak admin console and set the environment
variables in the Open WebUI deployment.

### Database & Websockets

Open WebUI requires PostgreSQL for its database. It also uses WebSockets for
real-time streaming during generation. The PostgreSQL instance is deployed
via ArgoCD in the `llm` namespace.

### Storage

Open WebUI stores uploaded documents, user avatars, and session data on a
PersistentVolumeClaim. The storage class is `local-path` for local storage
or `csi-vsphere` for shared storage (when available).

### Document RAG

RAG (Retrieval-Augmented Generation) allows Open WebUI to answer questions
based on uploaded documents. Documents are embedded and stored in the vector
store, then retrieved during generation.

#### Why embeddings run on CPU (not the B70)

Embedding models are **small and fast on CPU**. The `llama-cpp-embed`
component (kept in this overlay) runs an embeddings server on CPU. The B70
is reserved for generation — embedding throughput is sufficient on CPU and
saves GPU VRAM for the large language model.

Embeddings are loaded by `llama-cpp-embed` and exposed via the Open WebUI
embedding backend configuration. No GPU resources are consumed for this step.

#### RAG vs. web search

RAG operates on uploaded documents only. Web search (via tools like DuckDuckGo)
is a separate capability. RAG is deterministic (based on your data); web
search is dynamic but uncontrolled.

#### Freshness / staleness

Uploaded documents are re-embedded on each upload. There is no automatic
re-indexing — stale documents must be manually removed and re-uploaded.
For automated document ingestion, see [Roadmap: connector auto-sync (Onyx)](#roadmap-connector-auto-sync-onyx).

## Roadmap: connector auto-sync (Onyx)

Planned: automated document ingestion connectors (GitHub repos, web scraping,
email) that continuously sync documents into the vector store. This would
eliminate manual document uploads and keep RAG data fresh.

See [Onyx](https://github.com/onflow/onyx) (or equivalent project) for
reference implementations. Integration into the ArgoCD application topology
is the next step once the connector architecture is decided.

## REF

- [llama.cpp Vulkan documentation](https://github.com/ggerganov/llama.cpp)
- [Intel Arc Pro B70 (Battlemage) architecture](https://www.intel.com)
- [Qwen3.6 model family](https://qwenlm.github.io)
- [llama-swap architecture](https://github.com/llama-swap/llama-swap)
- [Open WebUI](https://github.com/open-webui/open-webui)
- [Mesa Vulkan drivers](https://mesa3d.org)
