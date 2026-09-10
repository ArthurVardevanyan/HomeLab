# Local LLM

GPU-backed local LLM serving for the homelab. The **default (`overlays/okd`)
backend is llama-swap** — chat models run on **vLLM XPU** with MTP
speculative decoding, embedding models run on **llama.cpp SYCL** — on the
Intel Arc Pro B70 (2× GPUs, 64 GB VRAM pooled). The host (`gpu-1`) is a
6-core/12-thread Ryzen 5 3600 with 82 GB RAM — see [Performance](#performance-backend-history-and-current-state)
for measured throughput and the Vulkan → SYCL → vLLM backend history.

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
  - [Performance: backend history and current state](#performance-backend-history-and-current-state)
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

| Overlay        | Backend                                                             | Hardware               | Notes                                          |
| -------------- | ------------------------------------------------------------------- | ---------------------- | ---------------------------------------------- |
| `overlays/okd` | **llama-swap** (vLLM XPU chat + llama.cpp SYCL embeddings, default) | Intel Arc Pro B70 (2×) | One model per GPU, data-parallel + spread sets |

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
    - targets: ["xpumd.intel-device-plugins-operator.svc.cluster.local.:8080"]
      labels: { app: intel-gpu }
    - targets: ["litellm-svc.llm.svc.cluster.local.:4000"]
      labels: { app: litellm }
    - targets: ["llama-swap-svc.llm.svc.cluster.local.:8080"]
      labels: { app: llama-swap }
    - targets: ["llama-swap-svc.llm.svc.cluster.local.:9100"]
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

### vLLM metrics (chat models, via metrics-exporter)

| Metric                                               | Type      | Description                                     |
| ---------------------------------------------------- | --------- | ----------------------------------------------- |
| `vllm:num_requests_running`                          | Gauge     | Concurrent decode tasks                         |
| `vllm:num_requests_waiting`                          | Gauge     | Requests in the scheduling queue                |
| `vllm:prompt_tokens_total`                           | Counter   | Prompt tokens processed                         |
| `vllm:generation_tokens_total`                       | Counter   | Decoded tokens generated                        |
| `vllm:kv_cache_usage_perc`                           | Gauge     | PagedAttention KV cache block utilization (0-1) |
| `vllm:prefix_cache_hits_total`                       | Counter   | KV cache prefix matching hits                   |
| `vllm:prefix_cache_queries_total`                    | Counter   | KV cache prefix matching queries                |
| `vllm:time_to_first_token_seconds_bucket`            | Histogram | Time from request to first output token         |
| `vllm:request_time_per_output_token_seconds_bucket`  | Histogram | Decode time per output token                    |
| `vllm:e2e_request_latency_seconds_bucket`            | Histogram | End-to-end request latency                      |
| `vllm:spec_decode_num_draft_tokens_total`            | Counter   | Speculative decoding draft tokens               |
| `vllm:spec_decode_num_accepted_tokens_total`         | Counter   | Accepted speculative tokens                     |
| `vllm:spec_decode_num_drafts_total`                  | Counter   | Speculative verification steps                  |
| `vllm:spec_decode_num_accepted_tokens_per_pos_total` | Counter   | Accepted tokens per draft position              |

All metrics carry the exporter-added `model` label (e.g. `35b-gpu0`, `27b-gpu1`),
so per-model dashboards/alerts use `{model="..."}` or `{model=~"$model"}`
selectors.

Verify from inside the pod:

```bash
export KUBECONFIG=$HOME/.kube/okd
# llama.cpp metrics (embed-spread)
oc -n llm exec deploy/llama-swap -c metrics-exporter -- curl -sS localhost:9100/metrics | grep '^llamacpp:' | head -5
# vLLM metrics (chat models)
oc -n llm exec deploy/llama-swap -c metrics-exporter -- curl -sS localhost:9100/metrics | grep '^vllm:' | head -5
```

> **Known limitation: transient scrape gaps under heavy load.** llama-server's
> `/metrics` endpoint shares the same small HTTP thread pool
> (`--threads-http 4`, set via `cmd_base_llama` in `llama-swap.yaml`) as
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
above), the per-model `llamacpp:*` panels (Overview/Performance/Concurrency/
Efficiency/Diagnostics rows, re-scoped to `{model="embed-spread"}`), and the
per-model `vllm:*` panels (new "vLLM Chat Models" and "Speculative Decoding
(MTP)" rows), templated on a `$model` variable
(`label_values(exporter_model_last_success_timestamp_seconds, model)`,
multi-select, default `All`).

## Performance: backend history and current state

### Current: vLLM XPU + MTP4 (2026-09-10)

Chat models run on vLLM XPU with MTP (Multi-Token Prediction) speculative
decoding: 27B dense achieves **~40–44 tok/s** clean decode, 35B-A3B MoE
achieves **~55–72 tok/s** (peak 112.2). See the llama-swap README's
[Measured Performance (2026-09-10)](components/llama-swap/README.md#measured-performance-2026-09-10)
for the full session-level breakdown, MTP acceptance-rate analysis, and
known gaps (position-4 acceptance tuning, long-running decay test,
concurrency, etc.).

### Backend history

| Era                    | Backend              | Config                         | Key numbers                                                                                              |
| ---------------------- | -------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Aug 12–14, 2026        | llama.cpp Vulkan     | f16 KV, dual GPU, ngram-simple | decode p50 20.6, p95 45.0, p99 70.2, max 76.7 t/s (n=847)                                                |
| Aug 14, 2026           | + `--load-mode none` |                                | working set 32 GiB → 4.7 GiB; cold load 82.3 s (still in effect on the embed model via `cmd_base_llama`) |
| Aug 18, 2026           | llama.cpp SYCL       | f16 KV, dual GPU               | 35B 1087–1230 t/s, 27B 862–1052 t/s (llama-swap Activity "Gen Speed" column)                             |
| Sep 10, 2026 (current) | vLLM XPU + MTP4      | GPTQ-Int4, fp8 KV cache        | 27B ~40–44 tok/s, 35B ~55–72 tok/s (vLLM engine 10s-window log means)                                    |

> **Open question — SYCL vs vLLM measurement gap:** the Aug 18 llama.cpp SYCL
> figures (862–1230 t/s) come from llama-swap's Activity page "Gen Speed"
> column; the Sep 10 vLLM figures (~40–72 tok/s) are 10-second-window means
> from the vLLM engine log. These are different measurement methodologies
> and are **not directly comparable** — the apparent ~20× gap has not been
> reconciled and should not be read as a confirmed regression.

### Historical: Vulkan-era CPU-dispatch-bound analysis

The Vulkan-era data (decode p50 20.6 t/s against a 76.7 t/s ceiling, n=847
requests) showed the median request running at roughly a quarter of the
observed maximum, while the GPU used only ~11% of its 608 GiB/s memory
bandwidth under dual-slot load — pointing at the decode loop being
**CPU-dispatch-bound, not GPU-bandwidth- or GPU-compute-bound**: 2
llama-server processes each defaulting to `-1` (auto-detect-all-cores)
threads, on a 6-core host also running LiteLLM, Open WebUI, Dragonfly, CNPG,
and (opportunistically) Tekton CI builds, inside a 5-CPU pod quota.
Mitigations applied 2026-08-14 (`--spec-type ngram-simple`, `--poll 0`,
thread tuning, a `1`-core CPU request/VPA floor) are captured in the
llama-swap README's [vLLM XPU Tuning Rationale](components/llama-swap/README.md#vllm-xpu-tuning-rationale)
(the historical llama.cpp flags now live in `cmd_base_llama`, used only by
the embedding model).

This analysis no longer applies to the **chat model path**: vLLM + MTP
operates differently, and [Measured Performance](components/llama-swap/README.md#measured-performance-2026-09-10)
shows MTP acceptance rate — not CPU dispatch or GPU bandwidth — is the
dominant factor in decode throughput.

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
│   ├── litellm/                 # gateway + llama_swap_affinity routing plugin
│   ├── open-webui/              # chat front-end
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

Items deliberately not implemented yet:

- **Model storage on node-local storage instead of `rook-ceph-block-ci`.**
  `gpu-1` has ~900 GB free on its node filesystem; a local PV would cut the
  ~20 GB cold-load time (82.3s observed off RBD; page-cache-warm second load
  was 7.3s — readahead loss from `--load-mode none` is a real cost, though
  the ~10× working-set reduction is the primary trade-off). Blocked on
  installing a local-storage provisioner (no LVM Storage / Local Storage
  Operator CSI driver is currently installed — only `rook-ceph.rbd`,
  `rook-ceph.cephfs`, and `csi.spiffe.io` exist on this cluster). Out of
  scope for a config-only tuning pass.
- **MTP `num_speculative_tokens: 3` vs `4` experiment.** Position-4 MTP
  draft-token acceptance is often <50% (see
  [Known Gaps](components/llama-swap/README.md#known-gaps)); testing
  3-token drafting is a low-cost tuning lever.
- **30+ minute long-running decode-decay test.** Sessions measured so far
  are ~4–5 minutes; a long session near KV cache exhaustion is needed to
  characterize decode decay under vLLM + MTP.
- **Multi-stream concurrency measurement.** Only single-stream tested so far
  (`--max-num-seqs 4`, 1 running request per model).
- **Prometheus percentiles for token latency.** Current data is 10-second
  window averages from vLLM engine logs; true p50/p99/p999 inter-token
  latency requires querying the vLLM `/metrics` endpoint directly.
- **Speculative output quality validation.** MTP uses a smaller draft model;
  confirm output quality matches the base model (human eval or benchmark
  comparison).
- **Reconcile the SYCL-era vs vLLM throughput measurement gap** — see
  [Backend history](#backend-history).
- **Open WebUI `TASK_MODEL` offload** — see
  [Task-model offload (deferred)](components/open-webui/README.md#task-model-offload-deferred).

## REF

- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [Intel Level Zero](https://github.com/oneapi-src/level-zero)
- [Qwen3.6 model family](https://qwenlm.github.io)
- [llama-swap](https://github.com/llama-swap/llama-swap)
- [Open WebUI](https://github.com/open-webui/open-webui)
- [Intel Arc Pro B70 (Battlemage) architecture](https://www.intel.com)
- [75 t/s on a single B70 (Reddit)](https://www.reddit.com/r/IntelArc/comments/1u3l4zx/qwen3635ba3b_at_75_tokens_per_second_on_a_single/)
- [Intel Arc B70 context decay: the KV cache setting that fixes it](https://jonathanmann.tech/blog/intel-arc-b70-context-decay-kv-cache/)
