# Local LLM

GPU-backed local LLM serving for the homelab. The **default (`overlays/okd`)
backend is llama-swap (SYCL)** orchestrating llama-server processes on the
Intel Arc Pro B70 (2× GPUs, 64 GB VRAM pooled). The host (`gpu-1`) is a
6-core/12-thread Ryzen 5 3600 with 82 GB RAM — see [Performance](#performance-why-decode-may-trail-bare-metal-benchmarks) for the CPU-side implications this has on decode throughput.

For GPU provisioning, see [intel-device-plugins](../intel-device-plugins/README.md).

## Table of Contents

- [Local LLM](#local-llm)
  - [Table of Contents](#table-of-contents)
  - [Component READMEs](#component-readmes)
  - [Backends / Overlays](#backends--overlays)
  - [GPU Monitoring](#gpu-monitoring)
  - [Metrics](#metrics)
    - [Prometheus metric names](#prometheus-metric-names)
    - [llama.cpp metrics via the metrics-exporter sidecar](#llamacpp-metrics-via-the-metrics-exporter-sidecar)
    - [Example PromQL queries](#example-promql-queries)
    - [Grafana dashboard](#grafana-dashboard)
  - [Performance: why decode may trail bare-metal benchmarks](#performance-why-decode-may-trail-bare-metal-benchmarks)
  - [Scaling](#scaling)
  - [Layout](#layout)
  - [Roadmap: connector auto-sync (Onyx)](#roadmap-connector-auto-sync-onyx)
  - [Future Work](#future-work)
  - [REF](#ref)

## Component READMEs

| Component                                     | Description                                                                |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| [llama-swap](components/llama-swap/README.md) | LLM orchestrator: model matrix, B70 tuning, SYCL, metrics-exporter sidecar |
| [LiteLLM](components/litellm/README.md)       | API gateway & GPU-aware routing plugin                                     |
| [Open WebUI](components/open-webui/README.md) | Chat front-end: OIDC, RAG, embeddings, storage                             |

## Backends / Overlays

| Overlay        | Backend                         | Hardware               | Notes                                          |
| -------------- | ------------------------------- | ---------------------- | ---------------------------------------------- |
| `overlays/okd` | **llama-swap + SYCL** (default) | Intel Arc Pro B70 (2×) | One model per GPU, data-parallel + spread sets |

## GPU Monitoring

Live Intel GPU telemetry tools are packaged in `containers/intel-gpu-monitor/`
and can be run on-demand with `oc debug` — no persistent deployment needed.
GPU power limits are managed by the `gpu-power-manager` DaemonSet (160W TDP
per GPU) — see [GPU Power Tuning Notes](../intel-device-plugins/GPU_POWER_TUNING.md)
for rationale, expected temperatures, and performance impact.

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
}

# Once inside the debug pod:
xpu-smi discovery
xpu-smi stats -d 0
xpu-smi dump -d 0 -m 0,1,2,3,5
intel_gpu_top -l
clinfo | grep -i "Device Name"
```

Workload-level metrics (llama-swap exposes Prometheus metrics via its
`/metrics` endpoint on port 8080; real `llamacpp:*` token-throughput metrics
are on the `metrics-exporter` sidecar's port 9100 — see [Metrics](#metrics)):

```bash
oc -n llm exec deploy/llama-swap -c llama-swap -- curl -sS "http://localhost:8080/metrics"
oc -n llm exec deploy/llama-swap -c metrics-exporter -- curl -sS "http://localhost:9100/metrics"
```

## Metrics

llama-swap exposes **proxy-level** Prometheus metrics on `/metrics` (port
8080). Real llama.cpp (`llamacpp:*`) token-throughput/decode metrics are
collected by a **metrics-exporter sidecar** (port 9100) — see
[llama.cpp metrics via the metrics-exporter sidecar](#llamacpp-metrics-via-the-metrics-exporter-sidecar)
below.

### Prometheus metric names

This cluster runs two Prometheus replicas; the same scrape jobs are defined
identically in both `kubernetes/prometheus/components/prometheus/config-map.yaml`
and `prometheus-nas/config-map.yaml`. LLM-stack targets (intel-gpu, LiteLLM,
and both llama-swap endpoints) share a single combined `llm` job, with
`app` distinguishing each target via per-target `static_configs` labels:

```yaml
- job_name: "llm"
  scrape_interval: 30s
  static_configs:
    - targets: ["xpumd.intel-device-plugins-operator.svc.cluster.local:8080"]
      labels: { app: intel-gpu }
    - targets: ["litellm-svc.llm.svc.cluster.local:4000"]
      labels: { app: litellm }
    - targets: ["llama-swap-svc.llm.svc.cluster.local:8080"]
      labels: { app: llama-swap }
    - targets: ["llama-swap-svc.llm.svc.cluster.local:9100"]
      labels: { app: llama-swap }
```

> **Known double-scrape (accepted, not yet fixed):** the static job above
> and `ServiceMonitor/llama-swap` (`components/llama-swap/service-monitor.yaml`)
> both scrape `llama-swap-svc:8080/metrics` **and**, since the
> metrics-exporter sidecar landed, `llama-swap-svc:9100/metrics` too.
> Harmless beyond a small amount of duplicate Prometheus series/storage;
> deduplicating is low priority.

Key metric families (llama-swap proxy only, no llama-server sub-scrapes):

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

### llama.cpp metrics via the metrics-exporter sidecar

Real `llamacpp:*` token-throughput/decode metrics require both:

1. llama-server started with `--metrics` — now set in `cmd_base`
   (`components/llama-swap/llama-swap.yaml`).
2. Solving llama-swap's **dynamic per-model port assignment**: each
   llama-server child gets a random `${PORT}` at runtime, so Prometheus
   can't scrape it directly with a static target.

Both are solved by the `metrics-exporter` sidecar container
(`containers/llama-swap-metrics-exporter/`, added to `deployment.yaml`,
built with `ko` — no Containerfile), exposing aggregated metrics on port
9100:

1. **Discovery** (every 10s): `GET http://localhost:8080/running` on
   llama-swap's own API returns the currently active model IDs and their
   assigned ports.
2. **Scrape**: for each active model,
   `GET http://localhost:<port>/metrics?model=<model_id>` against the
   llama-server child directly (`?model=` is required in llama-swap's
   router mode).
3. **Re-export**: scraped series are re-exposed on the sidecar's own
   `/metrics` (port 9100) with a `model="<model_id>"` label added, giving
   Prometheus one static target regardless of how many models are loaded
   or which ports they're on.

The `Service`/`ServiceMonitor` (`service.yaml`, `service-monitor.yaml`)
expose/scrape this as the named `metrics` port; the static Prometheus
configs (`kubernetes/prometheus/components/prometheus{,-nas}/config-map.yaml`)
scrape the same port 9100 as one of the targets in the combined `llm` job
(`app="llama-swap"`).

Key `llamacpp:*` metrics (see `notes/llama-swap-metrics.md` for the full
design writeup):

| Metric                                    | Type    | Description                         |
| ----------------------------------------- | ------- | ----------------------------------- |
| `llamacpp:prompt_tokens_total`            | Counter | Prompt tokens processed             |
| `llamacpp:prompt_seconds_total`           | Counter | Prompt process time                 |
| `llamacpp:prompt_tokens_seconds`          | Gauge   | Average prompt throughput (t/s)     |
| `llamacpp:tokens_predicted_total`         | Counter | Generation tokens processed         |
| `llamacpp:tokens_predicted_seconds_total` | Counter | Predict process time                |
| `llamacpp:predicted_tokens_seconds`       | Gauge   | Average generation throughput (t/s) |
| `llamacpp:requests_processing`            | Gauge   | Requests currently processing       |
| `llamacpp:requests_deferred`              | Gauge   | Requests deferred (queued)          |
| `llamacpp:n_tokens_max`                   | Counter | High-watermark context size seen    |
| `llamacpp:n_decode_total`                 | Counter | Total `llama_decode()` calls        |
| `llamacpp:n_busy_slots_per_decode`        | Gauge   | Average busy slots per decode       |

All of these carry the exporter-added `model` label (e.g. `35b-gpu0`,
`27b-gpu1`), so per-model dashboards/alerts use
`{model="..."}` or `{model=~"$model"}` selectors.

Verify from inside the pod:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm exec deploy/llama-swap -c metrics-exporter -- curl -sS localhost:9100/metrics | grep '^llamacpp:'
```

> **Known limitation: transient scrape gaps under heavy load.** llama-server's
> `/metrics` endpoint shares the same small HTTP thread pool
> (`--threads-http 8`, see [B70 tuning rationale](components/llama-swap/README.md#b70-tuning-rationale)) as
> the rest of its API. Observed directly: a 125K-token prompt on `35b-gpu0`
> blocked its `/metrics` endpoint for several minutes (`context deadline
exceeded` in the exporter logs) while the manual `curl` against the same
> endpoint succeeded instantly once the request finished — i.e. this is
> llama-server being genuinely busy, not an exporter bug. The exporter
> mitigates this by:
>
> - a 15s per-model scrape timeout (`defaultScrapeTimeout` in `main.go`),
>   generous enough for most transient contention without hanging a whole
>   scrape cycle,
> - serving the **last successfully-scraped value** for a model when a
>   scrape fails, for up to 5 minutes (`maxStaleness`) — avoids a full data
>   gap in Grafana during exactly the busiest, most-interesting moments,
> - `exporter_model_last_success_timestamp_seconds{model="..."}` — alert on
>   `time() - exporter_model_last_success_timestamp_seconds > N` if a model
>   goes stale for longer than expected,
> - throttled error logging (first failure, then every 6th) instead of one
>   log line per 10s discovery cycle.

### Example PromQL queries

```promql
# --- llama-swap proxy metrics (host-level) ---

# Average CPU utilization across all cores
avg(llamaswap_cpu_util_percent)

# Memory usage percentage
llamaswap_memory_used_bytes / llamaswap_memory_total_bytes * 100

# Load average
llamaswap_load_average

# Network throughput (bytes/sec)
rate(llamaswap_network_bytes_total[5m])

# --- llamacpp metrics (per-model, via metrics-exporter) ---

# Generation throughput per model
llamacpp:predicted_tokens_seconds{model=~"$model"}

# Active/deferred requests per model
llamacpp:requests_processing{model=~"$model"}
llamacpp:requests_deferred{model=~"$model"}

# Prompt latency (ms/token), rate-derived
1000 * rate(llamacpp:prompt_seconds_total{model=~"$model"}[5m])
  / rate(llamacpp:prompt_tokens_total{model=~"$model"}[5m])
```

### Grafana dashboard

`kubernetes/grafana/base/dashboards/llama-swap.json` contains both the
host-level llama-swap panels (Memory/CPU/Network, from the proxy metrics
above) and the per-model `llamacpp:*` panels (Overview/Performance/
Concurrency/Efficiency/Diagnostics rows), templated on a `$model` variable
(`label_values(llamacpp:requests_processing, model)`, multi-select,
default `All`).

## Performance: why decode may trail bare-metal benchmarks

The B70 is a **PCIe Gen4 x8** GPU; the exact host slot bandwidth on `gpu-1`
has not been re-verified since the hardware correction above, so treat any
specific Gen/lane-count claim here with caution until it's re-measured. What
**has** been measured directly (`/api/metrics/stats`, n=778 requests):
decode p50 **20.6 t/s**, p95 45.0 t/s, p99 70.2 t/s, max 76.7 t/s — the
median request runs at roughly a quarter of the observed ceiling.

That gap, combined with the GPU using only ~11% of its 608 GiB/s memory
bandwidth under dual-slot load (see [KV cache: f16 vs q8_0](components/llama-swap/README.md#kv-cache-f16-vs-q8_0)),
points at the decode loop being **CPU-dispatch-bound, not GPU-bandwidth- or
GPU-compute-bound**: 2 llama-server processes each defaulting to `-1`
(auto-detect-all-cores) threads, on a 6-core host also running LiteLLM, Open
WebUI, Dragonfly, CNPG, and (opportunistically) Tekton CI builds, inside a
5-CPU pod quota. The Vulkan submit thread was very plausibly starved of CPU
time between GPU dispatches. Mitigations applied 2026-08-14 — `--spec-type
ngram-simple`, `--poll 0`, `-t 2 --threads-http 8`, a `1`-core CPU
request/VPA floor — are in [B70 tuning rationale](components/llama-swap/README.md#b70-tuning-rationale)
above. Re-measure `/api/metrics/stats` after rollout to confirm effect size;
numbers above are the pre-change baseline, not yet superseded.

## Scaling

For higher throughput:

- **Data parallel** (`dual_35b`, `dual_27b`): llama-swap runs the same model
  on both GPUs. Each slot gets a full 22 GB weight copy, but concurrent
  requests get full throughput on both cards, both GPUs always required.
- **Mixed** (`dual_35b0-27b1`, `dual_35b0d-27b1`, `dual_27b0-35b1`,
  `dual_27b0-35b1d`): 35B on one GPU + 27B on the other. The solver picks
  the mixed set when a cross-family request arrives and the other GPU
  already has a model, avoiding unnecessary eviction.
- **Spread** (`spread_35b`): one model spanning both GPUs via
  `--split-mode layer --tensor-split 1,1`.
- **Multiple llama-swap replicas** with a LoadBalancer: add replicas in
  `overlays/okd/llama-swap.yaml` and expose via a LoadBalancer service.
  llama-swap's config matrix handles the shared hardware — no external
  orchestrator needed for GPU-aware scheduling.
- **Horizontal Pod Autoscaler** (HPA): not yet configured. With data parallel
  mode and ~2 slots per GPU, the current setup handles concurrent requests
  well. Add HPA once load patterns are measured.

## Layout

> **Correction:** an earlier version of this diagram described
> `base/llama-swap.yaml`, `base/llama-swap-configmap.yaml`, and a top-level
> `config/llama-swap.yaml` — none of these paths exist. The actual layout is
> below.

```text
kubernetes/llm/
├── base/
│   ├── namespace.yaml           # llm Namespace (PSS restricted, GPU toleration)
│   └── network-policy.yaml
├── components/                  # one directory per app, each a Kustomize Component
│   ├── llama-swap/              # orchestrator: Deployment, Service, PVCs,
│   │   │                        # llama-swap.yaml (model matrix, mounted via
│   │   │                        # configMapGenerator — no separate config/ dir)
│   │   │                        # also runs the metrics-exporter sidecar
│   │   │                        # (containers/llama-swap-metrics-exporter/)
│   │   └── llama-swap.yaml      # the actual model matrix config
│   ├── llama-cpp-embed/         # CPU embeddings for Open WebUI (kept)
│   ├── litellm/                 # gateway + llama_swap_affinity routing plugin
│   ├── open-webui/               # chat front-end
│   ├── searxng/                  # web-search backend for Open WebUI
│   ├── model-downloader/         # CronJob (suspended) to (re)fetch GGUFs
│   ├── dragonfly-litellm/, dragonfly-open-webui/  # Redis-compatible caches
│   ├── cnpg-litellm/, cnpg-open-webui/            # CloudNativePG Postgres
│   └── *-gateway/                # Gateway API HTTPRoute + Certificate per app
├── overlays/
│   └── okd/
│       ├── kustomization.yaml   # composes base + all components for this cluster
│       └── egress-firewall.yaml
└── README.md                    # this file
```

## Roadmap: connector auto-sync (Onyx)

Planned: automated document ingestion connectors (GitHub repos, web scraping,
email) that continuously sync documents into the vector store. This would
eliminate manual document uploads and keep RAG data fresh.

See [Onyx](https://github.com/onyx-dot-app/onyx) (or equivalent project) for
reference implementations. Integration into the ArgoCD application topology
is the next step once the connector architecture is decided.

## Future Work

Items identified during the 2026-08-14 performance review, deliberately not
implemented yet:

- **Model storage on node-local storage instead of `rook-ceph-block-ci`.**
  `gpu-1` has ~900 GB free on its node filesystem; a local PV would cut the
  ~20 GB cold-load time (82.3s observed off RBD; page-cache-warm second load
  was 7.3s — readahead loss from `--load-mode none` is a real cost, though
  the ~10× working-set reduction is the primary trade-off). Blocked on
  installing a local-storage provisioner (no LVM Storage / Local Storage
  Operator CSI driver is currently installed — only `rook-ceph.rbd`,
  `rook-ceph.cephfs`, and `csi.spiffe.io` exist on this cluster). Out of
  scope for a config-only tuning pass.
- **Re-measure decode throughput** (`/api/metrics/stats`) after `ngram-mod` rollout to confirm effect size.
- **Open WebUI `TASK_MODEL` offload** — see
  [Task-model offload (deferred)](components/open-webui/README.md#task-model-offload-deferred).
- **`llm-embed` thread/CPU-limit mismatch** — see the note under
  [Embeddings (CPU)](components/open-webui/README.md#embeddings-cpu).

## REF

- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [Intel Level Zero](https://github.com/oneapi-src/level-zero)
- [Qwen3.6 model family](https://qwenlm.github.io)
- [llama-swap](https://github.com/llama-swap/llama-swap)
- [Open WebUI](https://github.com/open-webui/open-webui)
- [Intel Arc Pro B70 (Battlemage) architecture](https://www.intel.com)
- [75 t/s on a single B70 (Reddit)](https://www.reddit.com/r/IntelArc/comments/1u3l4zx/qwen3635ba3b_at_75_tokens_per_second_on_a_single/)
- [Intel Arc B70 context decay: the KV cache setting that fixes it](https://jonathanmann.tech/blog/intel-arc-b70-context-decay-kv-cache/)
