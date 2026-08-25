# llama-swap (LLM Orchestrator)

llama-swap orchestrates llama-server process lifecycles on the **Intel Arc Pro
B70 (2× GPUs, 64 GB VRAM pooled)** via a config-driven model matrix. Each
model is launched as an independent llama-server instance bound to one of the
two GPUs (`ONEAPI_DEVICE_SELECTOR=level_zero:0` or `1`).

## Table of Contents

- [llama-swap (LLM Orchestrator)](#llama-swap-llm-orchestrator)
  - [Table of Contents](#table-of-contents)
  - [Model Matrix](#model-matrix)
  - [B70 Tuning Rationale](#b70-tuning-rationale)
  - [Memory model](#memory-model)
    - [Per-GPU VRAM (static at load)](#per-gpu-vram-static-at-load)
    - [Host RAM (anonymous, per-instance)](#host-ram-anonymous-per-instance)
    - [Page cache (reclaimable)](#page-cache-reclaimable)
    - [Node-level accounting](#node-level-accounting)
    - [Summary](#summary)
  - [KV cache: f16 vs q8_0](#kv-cache-f16-vs-q8_0)
  - [Why not `--mlock` / `--ngl all`](#why-not---mlock----ngl-all)
  - [GPU Backend: SYCL (not Vulkan)](#gpu-backend-sycl-not-vulkan)
    - [Image tag](#image-tag)
  - [Scaling](#scaling)
  - [Metrics](#metrics)
    - [Proxy metrics](#proxy-metrics)
    - [llama.cpp metrics (via metrics-exporter sidecar)](#llamacpp-metrics-via-metrics-exporter-sidecar)
  - [MTP Speculative Decoding Experiment (2026-08-25)](#mtp-speculative-decoding-experiment-2026-08-25)
  - [References](#references)

## Model Matrix

Each model is launched as an independent llama-server instance bound to one of
the two GPUs (`ONEAPI_DEVICE_SELECTOR=level_zero:0` or `1`). The matrix
guarantees **exactly one model per GPU** per set — no stacking, no spillover.

| Model id                            | Model                                    | Trait                             | Vision |
| ----------------------------------- | ---------------------------------------- | --------------------------------- | ------ |
| `35b-gpu0` / `35b-gpu1`             | Qwen3.6-35B-A3B (sparse MoE)             | ~4x faster decode on B70          | Yes    |
| `35b-gpu0-dense` / `35b-gpu1-dense` | Same, `--ctx-size 262144`, 1 slot        | Full native context on single GPU | Yes    |
| `27b-gpu0` / `27b-gpu1`             | Qwen3.8-27B (dense), `--ctx-size 196608` | higher quality, slower            | Yes    |
| `35b-spread`                        | Qwen3.6-35B-A3B, both GPUs               | 1M ctx, parallel 4                | Yes    |

> **27B context:** Set to `196608` (192K). Qwen3.8 uses a hybrid architecture
> where 16 of 65 blocks use full attention (the other 49 use linear attention
> with no KV cache). At 64 KiB/token, the KV pool is 12.0 GiB at full context;
> total VRAM usage (15.95 GiB weights + 0.86 GiB mmproj + 12.0 GiB KV = 28.8
> GiB) fits with 3.2 GiB headroom on a 32 GB card.

The **matrix** uses sets that pick exactly one model per GPU. The solver picks
a set, guaranteeing at most one model per GPU:

- **Dual** (same model on both GPUs): `dual_35b`, `dual_35b-d`,
  `dual_35b-0d-1`, `dual_35b-0-1d`, `dual_27b` — requires both GPUs,
  provides
  redundancy and doubles throughput for concurrent requests.
- **Mixed dual** (35B on one GPU + 27B on the other): `dual_35b0-27b1`,
  `dual_35b0d-27b1`, `dual_27b0-35b1`, `dual_27b0-35b1d` — allows mixing
  model families across GPUs for maximum flexibility.
- **Spread** (one model spanning both GPUs): `spread_35b` — uses
  `--split-mode layer`.

| Set type      | Effect                                                                   |
| ------------- | ------------------------------------------------------------------------ |
| `dual_*`      | Same family on both GPUs (e.g. `dual_35b` = 35B on GPU 0 + 35B on GPU 1) |
| `dual_35b0-*` | 35B on GPU 0 + 27B on GPU 1                                              |
| `dual_27b0-*` | 27B on GPU 0 + 35B on GPU 1                                              |
| `spread_*`    | One instance using both GPUs                                             |

Models with `ttl: 0` stay resident in VRAM 24/7. Real telemetry on gpu-1 shows
idle card power (6.8 W with model resident) is indistinguishable from idle with
no model (7.2 W), so unloading buys zero wattage.

> **Probes:** llama-swap health is `GET /` on port 8080 — returns HTTP 200 when
> the orchestrator is running (regardless of whether a llama-server process is
> loading). Do **not** put liveness on a llama-server-specific endpoint — it
> flaps during model swaps and would kill the container mid-load.
>
> **Session IDs:** llama-swap's Activity page displays per-session IDs when
> clients send `X-Session-ID` or `X-Litellm-Session-Id` headers (the
> defaults). This is now **enabled** via `FORWARD_SESSION_INFO_HEADER_CHAT_ID=X-Session-ID`
> in Open WebUI and `forward_client_headers_to_llm_api: true` in LiteLLM.
> The `X-Session-ID` header propagates: Open WebUI → LiteLLM → llama-swap.

## B70 Tuning Rationale

Base args passed to each managed llama-server process (in `cmd_base` of
`llama-swap.yaml`), informed by B70 benchmarking:

- `--parallel 2` — two slots per llama-server instance for concurrent requests
  to the same model.
- `--cont-batching` — continuous batching for higher throughput.
- `--split-mode none` — no layer splitting across GPUs (each model runs on a
  single GPU; spread models use `--split-mode layer` in their own command).
- `--ubatch-size 2048` — larger physical batch is a big prefill win on
  Battlemage (opposite of the well-known AMD "smaller ubatch" advice).
- `--cache-type-k f16 --cache-type-v f16` — see [KV cache: f16 vs q8_0](#kv-cache-f16-vs-q8_0)
  below. Chosen over q8_0 because the B70 is **latency/compute-bound, not
  bandwidth-bound**, so the dequant-removal favors f16 at deep context.
- `--jinja` — Jinja template support for ChatML-style prompts.
- `--ctx-size 327680` — 320K default (overridden per-model in some sets).
  The 35B-A3B models use 320K; the 27B models use 192K to fit within
  32 GB VRAM; the spread models use 1M.
- Unified KV pool (llama-server default): a single pool of `ctx-size` shared
  across all parallel slots, fully pre-allocated to VRAM at load time (~28 GiB
  observed, static), no per-slot static capacity, no spillover because the
  total fits.
- `--reasoning-format auto` — reasoning format handled per-request by the client.
- `-ngl 99` — all layers offloaded to GPU.
- Flash attention on.
- `--spec-type ngram-mod` — model-free (n-gram) speculative decoding.
  Replaced `ngram-simple` to test more aggressive drafting (more tokens
  drafted per forward pass). Results documented in [MTP Speculative
  Decoding Experiment](#mtp-speculative-decoding-experiment-2026-08-25).
- `--poll 0` — disables ggml threadpool spin-waiting (default: 50). With
  `-ngl 99` the threadpool does almost no real work; spinning was competing
  with the SYCL dispatch thread for the same physical cores.
- `-t 12 --threads-http 4` — 12 inference threads to spread dispatch across
  all 12 physical cores, spreading the pegged dispatch-thread bottleneck.
- `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1` — enables parallel SYCL
  command lists so each inference thread submits directly to the GPU instead
  of funneling through a single dispatch queue.
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
  `rook-ceph_block_ci`/RBD/ext4): llama.cpp logged "read_raw_unsafe: Falling
  back to buffered IO due to Bad address" (EFAULT from O_DIRECT on the
  unaligned path) and fell back to plain buffered reads — which is what `none`
  requests directly, without the failed-attempt overhead. Trade-off: `none`
  uses kernel readahead on load but does not inflate the working set during
  decode. Observed cold-load time: 82.3s (page-cache-warm second load: 7.3s).
  `--load-mode` supersedes the deprecated `--mlock`/`--mmap`/`--no-mmap`
  flags — see [Why not `--mlock`](#why-not---mlock----ngl-all) below, which
  predates this flag's introduction.

## Memory model

This section describes the measured breakdown of RAM and VRAM usage across
llama-swap pod lifecycle. The unified KV pool (llama-server default) is fully
pre-allocated in VRAM at load time — **nothing spills to host RAM**.

### Per-GPU VRAM (static at load)

VRAM usage is fixed at load and does not grow with session activity. The total
includes weights, mmproj, and the full KV pool at configured `ctx-size`:

| Model         | Weights   | mmproj   | KV pool  | Total    | Headroom |
| ------------- | --------- | -------- | -------- | -------- | -------- |
| 35B-A3B       | 20.6 GiB  | 0.86 GiB | 6.25 GiB | 27.7 GiB | 4.3 GiB  |
| 35B-A3B-dense | 20.6 GiB  | 0.86 GiB | 4.00 GiB | 25.5 GiB | 6.5 GiB  |
| 27B           | 15.95 GiB | 0.86 GiB | 12.0 GiB | 28.8 GiB | 3.2 GiB  |

KV pool sizes: 35B-A3B at 320K uses 20 KiB/token (6.25 GiB pool); dense at
256K uses 16 KiB/token (4.0 GiB pool); 27B at 192K uses 64 KiB/token
(12.0 GiB pool). **Observed:** VRAM climbs to ~28 GiB on load and holds
there forever — consistent with a full static pool, not incremental growth.

### Host RAM (anonymous, per-instance)

| Component                                           | Size       | Behavior                                                                                                                                                                                                              |
| --------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Baseline (mmproj on host + SYCL/Level-Zero runtime) | ~1 GiB     | Allocated at load, stays flat                                                                                                                                                                                         |
| Usage high-water mark                               | 0 → ~9 GiB | SYCL host staging/pinned buffers + oneDNN compute buffers + glibc arena fragmentation from 12-thread cont-batching/spec-decode; THP-inflated (AnonHugePages ≈ 60–80% of Pss_Anon); climbs with session load, plateaus |
| Freed on swap                                       | yes        | When the llama-server instance is killed (model swap), all anonymous memory is returned to the cgroup                                                                                                                 |

Measured from a fresh 35B instance (idle, 12K tokens): **905 MiB** Pss_Anon.
Measured from a heavily-used 35B instance (94K+ tokens): **~10.3 GiB** Pss_Anon.
Measured from a 27B instance at 159K-token KV high-water mark: **1.97 GiB** Pss_Anon — proving the KV pool itself is not on the host (if it were, KV churn would drive host anon proportional to tokens).

### Page cache (reclaimable)

`--load-mode none` performs plain buffered reads of the GGUF, populating
kernel page cache: 12–18 GiB across both model files. This shows as
`active_file`/`inactive_file` in cgroup `memory.stat` and is fully reclaimable
under pressure. `oc adm top` workingSet excludes reclaimable file cache.

### Node-level accounting

The node `gpu-1` reports an "untracked" gap of **0.8 GiB** between per-pod
accounting and total node usage — attributable to Level Zero driver metadata
and is negligible.

### Summary

- VRAM: static ~28 GiB per GPU at load. No spillover.
- Host anonymous: bounded by usage high-water mark; freed on model swap;
  never unbounded or leaky.
- Page cache: reclaimable; does not affect VPA workingSet calculations.
- Node untracked: <1 GiB; driver overhead.

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

The fit is **measured**, not inferred:

| Model                | Weights   | mmproj   | KV/token | Pool at ctx | Total    | Headroom   |
| -------------------- | --------- | -------- | -------- | ----------- | -------- | ---------- |
| 35B-A3B (320K)       | 20.6 GiB  | 0.86 GiB | 20 KiB   | 6.25 GiB    | 27.7 GiB | 4.3 GiB    |
| 35B-A3B-dense (256K) | 20.6 GiB  | 0.86 GiB | 16 KiB   | 4.0 GiB     | 25.5 GiB | 6.5 GiB    |
| 27B (192K)           | 15.95 GiB | 0.86 GiB | 64 KiB   | 12.0 GiB    | 28.8 GiB | 3.2 GiB    |
| spread (1M)          | 20.6 GiB  | 0.86 GiB | 20 KiB   | 19.07 GiB   | 40.5 GiB | — (2× GPU) |

Pool is fully pre-allocated in VRAM at load time (observed ~28 GiB per GPU, static).
If the pod OOMs on model load or pushes VRAM over 32 GB, revert
`cache-type-k`/`cache-type-v` to `q8_0` (one-line change in `llama-swap.yaml`).

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

## GPU Backend: SYCL (not Vulkan)

llama-swap uses Intel's SYCL/Level Zero backend (`ONEAPI_DEVICE_SELECTOR`
env vars) rather than Vulkan. Each model in the matrix specifies its target
GPU explicitly:

- `ONEAPI_DEVICE_SELECTOR=level_zero:0` — GPU 0
- `ONEAPI_DEVICE_SELECTOR=level_zero:1` — GPU 1
- `ONEAPI_DEVICE_SELECTOR=level_zero:*` — spread models (both GPUs)

The base image is `ghcr.io/mostlygeek/llama-swap:v250-intel-b10450` which
includes a SYCL-built `llama-server` binary. No Mesa/Vulkan userspace is
needed.

### Image tag

The custom image is
`registry.arthurvardevanyan.com/homelab/llama-swap:v250-b10450` — the tag
encodes the llama-swap version (`v250`) and the upstream llama.cpp build
number (`b10450`). Renovate-managed; when Renovate proposes a bump in the
containerfile it triggers a PaC build that pushes the new tag.

Confirm the SYCL backend from inside the pod:

```bash
export KUBECONFIG=$HOME.kube/okd
oc -n llm exec deploy/llama-swap -- /app/llama-server --help 2>&1 | grep -iE "sycl|level.zero|ze"
# or, from a debug pod with gpu.intel.com/xe request:
xpu-smi stats -d 0
clinfo | grep -i "Device Name"
```

## Scaling

For higher throughput:

- **Dual** (`dual_35b`, `dual_35b-d`, `dual_35b-0d-1`, `dual_35b-0-1d`,
  `dual_27b`): one model per GPU, same family, both GPUs always required.
  Provides
  redundancy and doubles throughput for concurrent requests.
- **Mixed dual** (`dual_35b0-27b1`, `dual_35b0d-27b1`, `dual_27b0-35b1`,
  `dual_27b0-35b1d`): 35B on one GPU + 27B on the other, for maximum
  flexibility without full-model loading.
- **Dense 35B** (`dual_35b-d`, `dual_35b-0d-1`, `dual_35b-0-1d`): same 35B
  model as dual but with `--ctx-size 262144` and 1 slot for maximum
  per-request context.
- **Spread** (`spread_35b`): one model spanning both GPUs via
  `--split-mode layer --tensor-split 1,1` for maximum context (1M).
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

## MTP Speculative Decoding Experiment (2026-08-25)

### What was tested

Speculative decoding with Multi-Token Prediction (MTP) on top of existing
n-gram speculation. Two model variants were evaluated against the baseline
n-gram-only (`--spec-type ngram-mod`) configuration:

- **27B** (Qwen3.8-27B): external MTP draft model (`mtp-Qwen3.8-27B-Q4_0.gguf`,
  1.28 GiB Q4_0) with `--spec-draft-n-max 2 --spec-type ngram-mod,draft-mtp`
- **35B-A3B** (Qwen3.6-35B-A3B): MTP head baked into the quantization file
  from `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` (approx. 0.5 GiB larger than the
  base `unsloth/Qwen3.6-35B-A3B-GGUF` version), with
  `--spec-draft-n-max 2 --spec-type ngram-mod,draft-mtp`

Both used `--cache-reuse 256` and a coding-agent workload (Open WebUI /
opencode sessions with 40–80K context).

### Results

#### 27B — ~0% gain

| Metric           | n-gram only | n-gram + MTP |
| ---------------- | ----------- | ------------ |
| Gen throughput   | ~21 t/s     | ~20 t/s      |
| Acceptance rate  | N/A         | ~59%         |
| Tokens/spec-step | ~2.4        | ~2.4         |
| VRAM overhead    | —           | +1.28 GiB    |

- MTP draft acceptance: pos0 76.3%, pos1 59.5%, pos2+ 0.4% (n-gram long matches)
- Avg draft tokens: 2.33/step, accepted: 1.43/step (27B)
- Position acceptance at pos2+ proves n-gram is the dominant path (n-gram long
  matches; MTP capped at n_max=2 so it can only contribute pos0/pos1)
- MTP only ran on n-gram miss steps, where the marginal gain was ~0

#### 35B-A3B — ~20% slower (confounded by VRAM pressure)

| Metric           | n-gram only | MTP file   |
| ---------------- | ----------- | ---------- |
| Gen throughput   | ~46–49 t/s  | ~35–37 t/s |
| Acceptance rate  | N/A         | ~52%       |
| Tokens/spec-step | ~2.5        | ~2.8       |

- Position acceptance: pos0 83.8%, pos1 70.4%, pos2+ (n-gram long matches)
- The MTP quant file is ~0.5 GiB larger. At ctx-size 327680 + parallel 2 the GPU
  is VRAM-constrained (weights + KV pool + MTP head approaches the 32 GB limit)
- The 294912 context-size change (reduces KV pool by ~0.5 GiB) should restore
  headroom, but as of this writing has not been deployed to the cluster

### Why MTP didn't help

On a coding-agent workload, n-gram speculation with `--cache-reuse 256` is
highly effective. Code output is full of exact repetitions (function calls,
imports, variable names, formatting patterns) that n-gram matches for free — no
draft model forward pass required. MTP only runs on steps where the n-gram cache
finds no match, where:

1. The draft acceptance rate is lower (the model's next token is less predictable
   without a preceding repetition to anchor on)
2. The draft forward pass cost is real — 1.37 GiB of weights streamed from GDDR6
   (~2–4 ms on the B70) plus a slightly larger verify batch
3. The marginal accepted tokens per step barely exceed the n-gram-only baseline

This matches the analysis in [Testing MTP with Qwen3.6 35B-A3B and 27B on Intel
Arc B70][1]: MTP provides meaningful speedup only when the base has _no_
speculation at all, or when n-gram matching is ineffective (non-repetitive output,
short prompts where cache misses dominate).

Three failure modes from the article that apply here:

1. **Acceptance rate < 60%** — our blended acceptance rates (52–59%) sit right at
   the threshold where MTP stops being beneficial
2. **VRAM pressure** — the MTP quant is ~0.5 GiB larger; at high ctx sizes this
   pushes the GPU over the edge, causing KV spillover to host RAM
3. **Graph recapture** — on Intel SYCL (Level Zero), dynamic-shaped draft passes
   can trigger per-step CUDA graph recapture, negating the draft cost savings
   (not verified empirically, but plausible for the observed slowdown)

### Conclusion

**Drop MTP speculation. N-gram-only (`--spec-type ngram-mod`) is the optimal
configuration for this hardware and workload.**

N-gram speculation provides the majority of the throughput benefit (2×+ over
non-speculative decode) at zero VRAM cost and zero additional forward passes.
MTP adds VRAM overhead and extra forward passes with negligible-to-negative
marginal gain on repetitive code workloads.

### How to re-test

To try MTP again in the future:

1. **Isolate the variable**: run the same workload with n-gram-only vs
   n-gram+MTP, keeping context size, parallelism, and prompt distribution
   identical. Use the Open WebUI activity log to compare generation speeds across
   matched session lengths.

2. **Control for VRAM**: measure the model file size difference; ensure KV pool
   fits comfortably in VRAM (leave ≥3 GiB headroom). Compare Pss_Anon
   (`/proc/<pid>/smaps_rollup`) — if it climbs with session load, KV is spilling
   to host RAM.

3. **Use spec decode metrics**: query
   `http://127.0.0.1:<port>/metrics` for:
   - `spec_decode_num_drafts_total` — total speculative steps
   - `spec_decode_num_accepted_tokens_total` — accepted draft tokens
   - `spec_decode_num_draft_tokens_total` — total draft tokens proposed
   - Calculate tokens/step = (accepted + bonus) / draft_steps
   - Calculate acceptance rate = accepted / draft_tokens
   - If acceptance rate < 60%, MTP is likely not worth the overhead

4. **Check which path runs**: position acceptance at pos2+ indicates n-gram is
   contributing (MTP is capped at n_max, so it only proposes pos0/pos1). If pos0
   acceptance is low, the draft model's predictions are poor for the workload.

5. **Watch for graph recapture**: on Intel SYCL / CUDA, dynamic-shaped draft
   passes can trigger per-step graph recapture. Monitor load times for sudden
   jumps or check llama.cpp logs for recapture warnings.

[1]: https://dev.to/arthur__huang/testing-multi-token-prediction-mtp-with-qwen36-35b-a3b-and-27b-on-intel-arc-b70-545i

## References

- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [llama-swap](https://github.com/llama-swap/llama-swap)
- [Intel Level Zero](https://github.com/oneapi-src/level-zero)
- [SYCL on Intel Arc](https://www.intel.com/content/www/us/en/developer/tools/oneapi/toolkits.html)
- [75 t/s on a single B70 (Reddit)](https://www.reddit.com/r/IntelArc/comments/1u3l4zx/qwen3635ba3b_at_75_tokens_per_second_on_a_single/)
- [Intel Arc B70 context decay: the KV cache setting that fixes it](https://jonathanmann.tech/blog/intel-arc-b70-context-decay-kv-cache/)
