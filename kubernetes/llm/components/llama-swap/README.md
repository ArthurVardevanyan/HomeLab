# llama-swap (LLM Orchestrator)

llama-swap orchestrates llama-server process lifecycles on the **Intel Arc Pro
B70 (2× GPUs, 64 GB VRAM pooled)** via a config-driven model matrix. Each
model is launched as an independent llama-server instance bound to one of the
two GPUs (`GGML_VK_VISIBLE_DEVICES=0` or `1`).

## Table of Contents

- [llama-swap (LLM Orchestrator)](#llama-swap-llm-orchestrator)
  - [Table of Contents](#table-of-contents)
  - [Model Matrix](#model-matrix)
  - [B70 Tuning Rationale](#b70-tuning-rationale)
  - [KV cache: f16 vs q8\_0](#kv-cache-f16-vs-q8_0)
  - [Why not `--mlock` / `--ngl all`](#why-not---mlock----ngl-all)
  - [Mesa 26.1 (biggest perf lever) — handled in the image](#mesa-261-biggest-perf-lever--handled-in-the-image)
    - [Image tag](#image-tag)
  - [Scaling](#scaling)
  - [Metrics](#metrics)
    - [Proxy metrics](#proxy-metrics)
    - [llama.cpp metrics (via metrics-exporter sidecar)](#llamacpp-metrics-via-metrics-exporter-sidecar)
  - [References](#references)

## Model Matrix

Each model is launched as an independent llama-server instance bound to one of
the two GPUs (`GGML_VK_VISIBLE_DEVICES=0` or `1`).

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

The **matrix** defines all valid VRAM combinations by pairing GPU 0 and GPU 1
models:

- **Data parallel** (same model duplicated on both cards): `dual_35b`,
  `dual_27b`, `dual_coder` — provides redundancy and doubles throughput for
  concurrent requests.
- **Mixed workloads** (different models side-by-side): `mix_1` through `mix_6`
  — e.g. `M35-0 & M27-1` loads 35B on GPU 0 and 27B on GPU 1.

| Set     | GPU 0                                 | GPU 1                                 |
| ------- | ------------------------------------- | ------------------------------------- |
| `mix_1` | Qwen3.6-35B-A3B (`35b-gpu0`)          | Qwen3.6-27B (`27b-gpu1`)              |
| `mix_2` | Qwen3.6-27B (`27b-gpu0`)              | Qwen3.6-35B-A3B (`35b-gpu1`)          |
| `mix_3` | Qwen3.6-35B-A3B (`35b-gpu0`)          | Qwen3-Coder-30B-A3B (`coder30b-gpu1`) |
| `mix_4` | Qwen3-Coder-30B-A3B (`coder30b-gpu0`) | Qwen3.6-35B-A3B (`35b-gpu1`)          |
| `mix_5` | Qwen3.6-27B (`27b-gpu0`)              | Qwen3-Coder-30B-A3B (`coder30b-gpu1`) |
| `mix_6` | Qwen3-Coder-30B-A3B (`coder30b-gpu0`) | Qwen3.6-27B (`27b-gpu1`)              |

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

## B70 Tuning Rationale

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

## KV cache: f16 vs q8_0

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

## Why not `--mlock` / `--ngl all`

> `--mlock`, `--mmap`/`--no-mmap` are **deprecated** in current llama-server
> builds in favor of the unified `-lm, --load-mode MODE` flag
> (`auto|none|mmap|mlock|mmap+mlock|dio`). This app now sets
> `--load-mode none` in `cmd_base` — see [B70 tuning rationale](#b70-tuning-rationale)
> above. The reasoning below (originally written against `--mlock`) still
> applies to why `mlock`/`mmap+mlock` modes are avoided.

- **`mlock` (via `--load-mode`) is intentionally NOT used.** The model is
  fully GPU-resident (`-ngl 99`), so decode reads weights from GDDR6, not
  host RAM — mlock would pin ~10+ GB of (capped, 64 GiB limit) host memory to
  protect pages that aren't on the decode path, risks OOM of the pod, and
  requires the `IPC_LOCK` capability the containers deliberately drop
  (`capabilities.drop: [ALL]`).
- **`none` was chosen over `mmap`/`auto`** specifically to avoid mmap'd model
  weights inflating the pod's page-cache-backed working set (`active_file`
  in cgroup `memory.stat`) well past what VPA had sized the request/target
  to. See the `--load-mode none` entry above for the measured before/after.
- **`--ngl all` is already covered** by `-ngl 99` in the base command.
  99 is the idiomatic "offload all layers" value; setting it in `cmd_base`
  prevents the silent CPU/MoE spill that tanks Battlemage decode. There is
  currently no verified way to confirm offload via `oc logs` — llama-swap
  does not forward child llama-server stdout into its own log stream. If
  decode is ever unexpectedly slow, verify `-ngl 99` is set in the config
  and check the running llama-server's process command line via `/proc/<pid>/cmdline`.

## Mesa 26.1 (biggest perf lever) — handled in the image

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
  quarter of it. See [Performance](../README.md#performance-why-decode-may-trail-bare-metal-benchmarks)
  for why, and [B70 tuning rationale](#b70-tuning-rationale) for the
  mitigations (`--spec-type`, thread/poll tuning) applied in response.

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

## Metrics

llama-swap exposes **proxy-level** Prometheus metrics on `/metrics` (port 8080).
Real `llamacpp:*` token-throughput metrics come from the **metrics-exporter
sidecar** (port 9100). See [llama.cpp metrics via the metrics-exporter sidecar](../README.md#llamacpp-metrics-via-the-metrics-exporter-sidecar) in the main README
for the full metric tables, Prometheus scrape configuration, and PromQL queries.

### Proxy metrics

| Metric                          | Type    | Description                                              |
| ------------------------------- | ------- | -------------------------------------------------------- |
| `llamaswap_cpu_util_percent`    | Gauge   | CPU utilization per core (0–100)                         |
| `llamaswap_memory_used_bytes`   | Gauge   | Used system memory (bytes)                               |
| `llamaswap_memory_total_bytes`  | Gauge   | Total system memory (bytes)                              |
| `llamaswap_load_average`        | Gauge   | Load average (labels: 1m, 5m, 15m)                       |
| `llamaswap_network_bytes_total` | Counter | Network bytes transferred (labels: interface, direction) |

### llama.cpp metrics (via metrics-exporter sidecar)

Key `llamacpp:*` metrics, each carrying a `model` label for per-model
dashboards/alerts:

| Metric                              | Type    | Description                         |
| ----------------------------------- | ------- | ----------------------------------- |
| `llamacpp:predicted_tokens_seconds` | Gauge   | Average generation throughput (t/s) |
| `llamacpp:prompt_tokens_total`      | Counter | Prompt tokens processed             |
| `llamacpp:requests_processing`      | Gauge   | Requests currently processing       |
| `llamacpp:requests_deferred`        | Gauge   | Requests deferred (queued)          |
| `llamacpp:n_tokens_max`             | Counter | High-watermark context size seen    |

The metrics-exporter sidecar discovers active models by polling
`GET /running` on the llama-swap API every 10s, scrapes each llama-server
child's `/metrics` endpoint directly (with `?model=<id>`), and re-exposes
aggregated series on port 9100 — giving Prometheus one static target regardless
of how many models are loaded. See [llama.cpp metrics via the metrics-exporter
sidecar](../README.md#llamacpp-metrics-via-the-metrics-exporter-sidecar) for the
complete discovery mechanism, transient scrape gap mitigations, and the full
metric table.

## References

- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [llama-swap](https://github.com/llama-swap/llama-swap)
