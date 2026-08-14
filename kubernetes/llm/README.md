# Local LLM

GPU-backed local LLM serving for the homelab. The **default (`overlays/okd`)
backend is llama-swap (Vulkan)** orchestrating llama-server processes on the
Intel Arc Pro B70 (2× GPUs, 64 GB VRAM pooled). The host (`gpu-1`) is a
6-core/12-thread Ryzen 5 3600 with 82 GB RAM — not the Pi 7 or Dell R740 XL
referenced in older notes; see [Performance](#performance-why-decode-may-trail-bare-metal-benchmarks)
for the CPU-side implications this has on decode throughput.

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
    - [llama.cpp metrics via the metrics-exporter sidecar](#llamacpp-metrics-via-the-metrics-exporter-sidecar)
    - [Example PromQL queries](#example-promql-queries)
    - [Grafana dashboard](#grafana-dashboard)
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
      - [Task-model offload (deferred)](#task-model-offload-deferred)
      - [RAG vs. web search](#rag-vs-web-search)
      - [Freshness / staleness](#freshness--staleness)
  - [Roadmap: connector auto-sync (Onyx)](#roadmap-connector-auto-sync-onyx)
  - [Future Work](#future-work)
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

> **27B context limit:** The dense 27B model's `ctx-size` is set to `196608`
> (98K/slot at parallel=2) in the config, 3/4 of the global 256K. The dense
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
>
> **Session IDs:** llama-swap's Activity page can display per-session IDs when
> clients send `X-Session-ID` or `X-Litellm-Session-Id` headers (the
> defaults). This is **not currently configured** — the Open WebUI → LiteLLM
> → llama-swap chain does not propagate session identifiers, so all requests
> show a dash. Enabling it would require injecting the header at some point
> in the request chain (e.g. via an Istio EnvoyFilter on the Open WebUI
> pod, or a header-forwarding config on Open WebUI/LiteLLM).

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
- `--spec-type ngram-simple` — model-free (n-gram) speculative decoding.
  Added 2026-08-14 after measured decode throughput (p50 ~20.6 t/s from
  `/api/metrics/stats`, n=778) came in far below the ~76 t/s single-stream
  ceiling: with `-ngl 99` and near-idle GPU bandwidth utilization during
  decode, the bottleneck is per-token dispatch overhead on the host's
  6-core/12-thread CPU, not GPU compute or memory bandwidth. Verifying N
  drafted tokens in one forward pass collapses N dispatch rounds into 1, at
  zero VRAM cost (no draft model). This workload's heavy prompt/context
  reuse (25.17M cache tokens vs 5.17M input tokens in the same sample) is a
  good match for n-gram lookup. `ngram-simple` is the conservative variant;
  `ngram-mod` (more aggressive drafting) is a candidate follow-up A/B.
- `--poll 0` — disables ggml threadpool spin-waiting (default: 50). With
  `-ngl 99` the threadpool does almost no real work; spinning was competing
  with the Vulkan submit thread for the same physical cores.
- `-t 2 --threads-http 2` — was `-1` (auto → 6 threads) on each of 2
  llama-server processes sharing a 6-core CPU inside the pod's 5-CPU quota,
  which also runs LiteLLM, Open WebUI, Dragonfly, and CNPG. Bound explicitly
  to stop threadpool oversubscription.
- `--cache-reuse 256` — allows KV reuse via shifting when a prompt changes
  mid-prefix (previously `0`/disabled). Matches how Open WebUI's context
  compaction, RAG re-injection, and tool-result insertion mutate prompts.
- `--load-mode none` — plain buffered reads, no mmap. After this change,
  cgroup `memory.stat` shows `active_file` ~2 MB (was ~20.6 GiB) and
  `inactive_file` ~23 GiB (page-cache-backed by buffered reads). Working set
  dropped from ~32 GiB (`oc adm top`: 32,177 Mi) to ~4.7 GiB (4,698 Mi) —
  well under the 16 GiB VPA floor. Confirmed via `/proc/<pid>/maps` that the
  GGUF is not mmapped (0 matching entries). `--load-mode dio` was tried first
  but provably does not work on this hardware + storage stack (gguf +
  `rook-ceph-block-ci`/RBD/ext4): llama.cpp logged "read_raw_unsafe: Falling
  back to buffered IO due to Bad address" (EFAULT from O_DIRECT on the
  unaligned path) and fell back to plain buffered reads — which is what `none`
  requests directly, without the failed-attempt overhead. Trade-off: `none`
  uses kernel readahead on load but does not inflate the working set during
  decode. Observed cold-load time: 82.3s (page-cache-warm second load: 7.3s).
  `--load-mode` supersedes the deprecated `--mlock`/`--mmap`/`--no-mmap`
  flags — see [Why not `--mlock`](#why-not---mlock----ngl-all) below, which
  predates this flag's introduction.

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
dequant tax f16 removes). f16 is used because the user routinely hits deep
(50K–100K+) context, where f16's removal of dequant overhead is the one real,
visible win, and because **repeated head-to-head testing on this hardware has
consistently measured q8_0 as slower**, not faster.

> Note: an earlier version of this doc justified identical decode speed
> between f16/q8_0 by claiming "the ~22 GB model-weight stream dwarfs the
> ~1–2 GB KV read." That argument doesn't hold for the A3B (sparse MoE)
> models — only ~3B params activate per token, so the per-token weight
> stream is closer to ~1.8 GB, the same order of magnitude as the KV read at
> deep context, not an order of magnitude larger. The empirical result (f16
> faster) stands; the bandwidth-dominance explanation for it does not. Keep
> f16 on the strength of repeated measurement, not this arithmetic.

The fit at 256K f16 is **inferred from an observed ~23 GB** (model + KV) on the
32 GB card, not measured headroom. **Rollback:** if the pod OOMs on model load
or pushes VRAM over 32 GB, revert `cache-type-k`/`cache-type-v` to `q8_0`
(one-line change in `llama-swap.yaml`) — the f16 fit is a judgement call, not
a guarantee.

### Why not `--mlock` / `--ngl all`

> `--mlock`, `--mmap`/`--no-mmap` are **deprecated** in current llama-server
> builds in favor of the unified `-lm, --load-mode MODE` flag
> (`auto|none|mmap|mlock|mmap+mlock|dio`). This app now sets
> `--load-mode dio` in `cmd_base` — see [B70 tuning rationale](#b70-tuning-rationale)
> above. The reasoning below (originally written against `--mlock`) still
> applies to why `mlock`/`mmap+mlock` modes are avoided.

- **`mlock` (via `--load-mode`) is intentionally NOT used.** The model is
  fully GPU-resident (`-ngl 99`), so decode reads weights from GDDR6, not
  host RAM — mlock would pin ~10+ GB of (capped, 64 GiB limit) host memory to
  protect pages that aren't on the decode path, risks OOM of the pod, and
  requires the `IPC_LOCK` capability the containers deliberately drop
  (`capabilities.drop: [ALL]`).
- **`dio` was chosen over `mmap`/`auto`** specifically to avoid mmap'd model
  weights inflating the pod's page-cache-backed working set (`active_file`
  in cgroup `memory.stat`) well past what VPA had sized the request/target
  to. See the `--load-mode dio` entry above for the measured before/after.
- **`--ngl all` is already covered** by `-ngl 99` in the base command.
  99 is the idiomatic "offload all layers" value; setting it in `cmd_base`
  prevents the silent CPU/MoE spill that tanks Battlemage decode. There is
  currently no verified way to confirm offload via `oc logs` — llama-swap
  does not forward child llama-server stdout into its own log stream. If
  decode is ever unexpectedly slow, verify `-ngl 99` is set in the config
  and check the running llama-server's process command line via `/proc/<pid>/cmdline`.

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

Confirm the fast path is active from inside the pod:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm exec deploy/llama-swap -- /app/llama-server --help 2>&1 | grep -i coopmat
# or, from a debug pod with gpu.intel.com/xe request:
vulkaninfo | grep -iE "Device Name|cooperativeMatrix"
```

> **Note:** `oc -n llm logs deploy/llama-swap | grep -i "matrix cores"` does
> not work — llama-swap does not forward child llama-server stdout into its own
> log stream. Use a debug pod with the same container image and GPU request to
> run `llama-server` directly if you need to inspect the cooperative-matrix
> load log.

Notes:

- Do **not** rely solely on llama.cpp's `matrix cores:` device line to confirm
  the fast path — recent builds report `KHR_coopmat` on hardware that
  previously reported `NV_coopmat2` at identical throughput. Verify with actual
  decode t/s. **Measured baseline** (`/api/metrics/stats`, n=778 requests):
  decode p50 **20.6 t/s**, p95 45.0 t/s, p99 70.2 t/s, max 76.7 t/s — i.e. the
  76.7 t/s ceiling is real but rare; the median request runs at roughly a
  quarter of it. See [Performance](#performance-why-decode-may-trail-bare-metal-benchmarks)
  for why, and [B70 tuning rationale](#b70-tuning-rationale) for the
  mitigations (`--spec-type`, thread/poll tuning) applied in response.

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
`27b-gpu1`, `coder30b-gpu0`), so per-model dashboards/alerts use
`{model="..."}` or `{model=~"$model"}` selectors.

Verify from inside the pod:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm exec deploy/llama-swap -c metrics-exporter -- curl -sS localhost:9100/metrics | grep '^llamacpp:'
```

> **Known limitation: transient scrape gaps under heavy load.** llama-server's
> `/metrics` endpoint shares the same small HTTP thread pool
> (`--threads-http 2`, see [B70 tuning rationale](#b70-tuning-rationale)) as
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

### TODO: Open WebUI metrics & cluster OTEL

- Open WebUI is not yet instrumented with a Prometheus metrics endpoint
  (see Open WebUI issue tracker for `prometheus_exporter` feature).
- Cluster-wide OTEL setup is planned. Until then, Grafana dashboards source
  metrics from Prometheus (llama-swap + llamacpp metrics).

## Performance: why decode may trail bare-metal benchmarks

> **Correction:** an earlier version of this doc attributed decode shortfall
> mainly to PCIe lane width on hardware ("Pi 7", "Dell R740 XL") that this
> overlay does not actually run on. The `gpu-1` node is a **6-core/12-thread
> Ryzen 5 3600** with 82 GB RAM and 2× Intel Arc Pro B70. PCIe bandwidth is
> still a factor (see below), but it is not the dominant one — see the
> CPU-dispatch-bound analysis that follows.

The B70 is a **PCIe Gen4 x8** GPU; the exact host slot bandwidth on `gpu-1`
has not been re-verified since the hardware correction above, so treat any
specific Gen/lane-count claim here with caution until it's re-measured. What
**has** been measured directly (`/api/metrics/stats`, n=778 requests):
decode p50 **20.6 t/s**, p95 45.0 t/s, p99 70.2 t/s, max 76.7 t/s — the
median request runs at roughly a quarter of the observed ceiling.

That gap, combined with the GPU using only ~11% of its 608 GiB/s memory
bandwidth under dual-slot load (see [KV cache: f16 vs q8_0](#kv-cache-f16-vs-q8_0)),
points at the decode loop being **CPU-dispatch-bound, not GPU-bandwidth- or
GPU-compute-bound**: 2 llama-server processes each defaulting to `-1`
(auto-detect-all-cores) threads, on a 6-core host also running LiteLLM, Open
WebUI, Dragonfly, CNPG, and (opportunistically) Tekton CI builds, inside a
5-CPU pod quota. The Vulkan submit thread was very plausibly starved of CPU
time between GPU dispatches. Mitigations applied 2026-08-14 — `--spec-type
ngram-simple`, `--poll 0`, `-t 2 --threads-http 2`, a `1`-core CPU
request/VPA floor — are in [B70 tuning rationale](#b70-tuning-rationale)
above. Re-measure `/api/metrics/stats` after rollout to confirm effect size;
numbers above are the pre-change baseline, not yet superseded.

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

# 3. Confirm cooperative matrix availability via vulkaninfo (load-time check
#    requires running llama-server in a debug pod since llama-swap does not
#    forward child stdout to its own log stream):
oc run coopmat-check --image=registry.arthurvardevanyan.com/homelab/llama-swap-vulkan \
  -n llm --rm -i --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "check",
      "image": "registry.arthurvardevanyan.com/homelab/llama-swap-vulkan:not_latest",
      "args": ["/app/llama-server", "-m", "/dev/null"],
      "resources": {"requests": {"gpu.intel.com/xe": "1"}, "limits": {"gpu.intel.com/xe": "1"}},
      "stdin": true, "tty": true,
      "volumeMounts": [{"name": "dri", "mountPath": "/dev/dri"}]
    }],
    "volumes": [{"name": "dri", "hostPath": {"path": "/dev/dri"}}]
  }
}' 2>&1 | grep -iE "matrix|cooperative"

# 4. Check GPU memory pressure:
oc -n llm exec deploy/llama-swap -- xpu-smi dump -d 0 -m 0,1,2,3,5 | head -20
#   Expected: memory used < 32 GB for single model load

# 5. Verify the llama-swap pod itself is running:
oc -n llm exec deploy/llama-swap -- curl -sS http://localhost:8080/ | python3 -m json.tool
#   Expected: HTTP 200 with JSON status

# 6. Check CPU contention on the node (dispatch-bound decode signature —
#    see Performance section above). A buildah/Tekton pod, VPA under-sizing
#    the llama-swap request, or another pod's limit burst can all starve the
#    Vulkan submit thread of CPU time between GPU dispatches:
oc adm top pods -n llm
oc get pods -A --field-selector spec.nodeName=gpu-1,status.phase=Running \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CPUREQ:.spec.containers[*].resources.requests.cpu,CPULIM:.spec.containers[*].resources.limits.cpu'
#   Expected: llama-swap has cpu request >= 1 (see deployment.yaml); no
#   large, currently-Running buildah/CI pod contending for the same 6 cores.

# 7. Check cgroup memory.stat (relevant with --load-mode none or dio):
oc -n llm exec deploy/llama-swap -- grep -E "^(anon|active_file|inactive_file) " /sys/fs/cgroup/memory.stat
#   Expected with --load-mode none: active_file ~0–3 MB, inactive_file ~20–24 GB,
#   working set ~4–5 GiB. If active_file is >10 GiB, the model is being mmapped
#   (check the image tag — an outdated build may not support --load-mode correctly).
```

If (1) fails (no cooperative matrix), the container has an old Mesa build.
If (2) fails (Mesa < 26.1), the image needs a rebuild.
If (3) fails (no cooperative matrix in llama-server load log), the llama-server
version may be too old.
If (6) shows CPU contention, that is now the primary suspect for decode
below the measured 20.6 t/s p50 baseline — not the GPU/Vulkan path.

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
PersistentVolumeClaim (`open-webui-data`, `ReadWriteMany`, `rook-cephfs`, 5Gi
— see `components/open-webui/pvc.yaml`).

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

> **Known oversubscription (not yet fixed):** `llama-cpp-embed` is started
> with `--threads 8` but the container's `resources.limits.cpu` is `"2"` —
> a 4× mismatch. Low priority given embeddings are small/fast regardless,
> but worth aligning (`--threads 2` or raising the CPU limit) if `gpu-1`'s
> CPU headroom becomes tighter after the llama-swap CPU-request increase
> above.

#### Task-model offload (deferred)

Open WebUI has no `TASK_MODEL` / `TASK_MODEL_EXTERNAL` configured, so
internal helper calls — chat title generation, tag generation, retrieval
query rewriting, and follow-up suggestions — all run against the same
public chat model (typically the 35B) as the user's actual request. The
observed input:output token ratio (5.17M input / 326K output tokens,
`/api/metrics/stats`) is consistent with meaningful task-call overhead
riding on top of real generation. Pointing `TASK_MODEL` at a smaller model,
or disabling individual features (`ENABLE_TAGS_GENERATION`,
`ENABLE_FOLLOW_UP_GENERATION`, etc.) via env vars in
`components/open-webui/deployment.yaml`, is a candidate follow-up — not yet
implemented.

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
- **`--spec-type ngram-mod` A/B against `ngram-simple`** (see
  [B70 tuning rationale](#b70-tuning-rationale)) once enough post-change
  `/api/metrics/stats` samples accumulate.
- **Open WebUI `TASK_MODEL` offload** — see
  [Task-model offload (deferred)](#task-model-offload-deferred).
- **`llm-embed` thread/CPU-limit mismatch** — see the note under
  [Why embeddings run on CPU](#why-embeddings-run-on-cpu-not-the-b70).

## REF

- [llama.cpp Vulkan documentation](https://github.com/ggerganov/llama.cpp)
- [Intel Arc Pro B70 (Battlemage) architecture](https://www.intel.com)
- [Qwen3.6 model family](https://qwenlm.github.io)
- [llama-swap architecture](https://github.com/llama-swap/llama-swap)
- [Open WebUI](https://github.com/open-webui/open-webui)
- [Mesa Vulkan drivers](https://mesa3d.org)
