# llama-swap (LLM Orchestrator)

llama-swap orchestrates **vLLM XPU** and **llama-server** process lifecycles on
the **Intel Arc Pro B70 (2× GPUs, 64 GB VRAM pooled)** via a config-driven
model matrix. Chat models (35B-A3B MoE, 27B dense) run on vLLM XPU with
Multi-Token Prediction (MTP) speculative decoding. Embedding models run on
llama-server (llama.cpp SYCL).

## Table of Contents

- [llama-swap (LLM Orchestrator)](#llama-swap-llm-orchestrator)
  - [Table of Contents](#table-of-contents)
  - [Model Matrix](#model-matrix)
  - [vLLM XPU Tuning Rationale](#vllm-xpu-tuning-rationale)
    - [vLLM serve flags (per-model in `llama-swap.yaml`)](#vllm-serve-flags-per-model-in-llama-swapyaml)
    - [MTP Speculative Decoding (vLLM)](#mtp-speculative-decoding-vllm)
    - [SYCL / Level Zero env](#sycl--level-zero-env)
  - [Measured Performance (2026-09-10)](#measured-performance-2026-09-10)
    - [27B Dense (GPU-1)](#27b-dense-gpu-1)
    - [35B-A3B MoE (GPU-0)](#35b-a3b-moe-gpu-0)
    - [MoE vs Dense](#moe-vs-dense)
    - [MTP Per-Position Acceptance](#mtp-per-position-acceptance)
    - [SaaS Comparison](#saas-comparison)
    - [Known Gaps](#known-gaps)
  - [Memory model](#memory-model)
    - [Per-GPU VRAM (static at load)](#per-gpu-vram-static-at-load)
    - [Host RAM (anonymous, per-instance)](#host-ram-anonymous-per-instance)
    - [Summary](#summary)
  - [GPU Backend: SYCL (not Vulkan)](#gpu-backend-sycl-not-vulkan)
    - [Image tag](#image-tag)
    - [Preload times](#preload-times)
  - [Scaling](#scaling)
  - [Metrics](#metrics)
    - [Proxy metrics](#proxy-metrics)
    - [Embedding model metrics (llama.cpp, via metrics-exporter sidecar)](#embedding-model-metrics-llamacpp-via-metrics-exporter-sidecar)
  - [References](#references)

## Model Matrix

Each model runs as an independent process bound to one of the two GPUs. The
matrix guarantees **exactly one model per GPU** per set — no stacking, no
spillover.

| Model id                | Backend   | Model                                         | Context |
| ----------------------- | --------- | --------------------------------------------- | ------- |
| `35b-gpu0` / `35b-gpu1` | vLLM      | Qwen3.6-35B-A3B (MoE, GPTQ-Int4, with vision) | 256K    |
| `27b-gpu0` / `27b-gpu1` | vLLM      | Qwen3.8-27B (dense, GPTQ-Int4, with vision)   | 131K    |
| `embed-spread`          | llama.cpp | Qwen3-Embedding-0.6B (Q8_0 GGUF)              | 120K    |

> `embed-spread` previously failed to load: plain `/app/llama-server` was
> segfaulting on CPU (`-ngl 0`, immediately after "llama threadpool init")
> and hanging on GPU (`-ngl 99`, host-side stall mid-layer-0 attention —
> VRAM allocated, GPU idle, one CPU thread pinned). Root cause was NOT a
> CPU-dispatch mismatch (haswell is the correct ggml CPU variant for this
> node's Ryzen 5 3600) and NOT a Battlemage-specific bug — it was this
> image's `LD_LIBRARY_PATH` putting vLLM's `/opt/venv/lib` (SYCL 9 stack)
> ahead of oneAPI, so llama-server bound vLLM's Intel OpenMP runtime
> instead of the oneAPI 2025.3 runtime it was built against. Fixed by
> routing llama.cpp through `llama-device-wrapper.sh`, which points it at a
> hermetic runtime vendored into `/app/rt/` (see the containerfile). See
> the `embed-spread` model comment in `llama-swap.yaml` for the full
> writeup.

The **matrix** uses sets that pick exactly one model per GPU. The solver picks
a set, guaranteeing at most one model per GPU:

- **Dual** (same model on both GPUs): `dual_35b`, `dual_27b`
  — requires both GPUs, provides redundancy and doubles throughput for
  concurrent requests.
- **Mixed dual** (35B on one GPU + 27B on the other): `dual_35b0-27b1`,
  `dual_27b0-35b1` — allows mixing model families across GPUs for maximum
  flexibility.
- **Embed spread** (chat models + embedding on both GPUs): `dual_35b-spread`,
  `dual_27b-spread`, `dual_35b0-27b1-spread`, `dual_27b0-35b1-spread` —
  embedding model runs alongside chat on both GPUs.
- **Embed spread standalone** (`embed_spread`): embedding-only mode when no
  chat is needed.

| Set type      | Effect                                                                   |
| ------------- | ------------------------------------------------------------------------ |
| `dual_*`      | Same family on both GPUs (e.g. `dual_35b` = 35B on GPU 0 + 35B on GPU 1) |
| `dual_35b0-*` | 35B on GPU 0 + 27B on GPU 1                                              |
| `dual_27b0-*` | 27B on GPU 0 + 35B on GPU 1                                              |

Models with `ttl: 0` stay resident in VRAM 24/7. Real telemetry on gpu-1 shows
idle card power (6.8 W with model resident) is indistinguishable from idle with
no model (7.2 W), so unloading buys zero wattage.

> **Probes:** llama-swap health is `GET /` on port 8080 — returns HTTP 200 when
> the orchestrator is running (regardless of whether a child process is loading).
> Do **not** put liveness on a child-specific endpoint — it flaps during model
> swaps and would kill the container mid-load.
>
> **Session IDs:** llama-swap's Activity page displays per-session IDs when
> clients send `X-Session-ID` or `X-Litellm-Session-Id` headers (the
> defaults). This is now **enabled** via `FORWARD_SESSION_INFO_HEADER_CHAT_ID=X-Session-ID`
> in Open WebUI and `forward_client_headers_to_llm_api: true` in LiteLLM.
> The `X-Session-ID` header propagates: Open WebUI → LiteLLM → llama-swap.

## vLLM XPU Tuning Rationale

### vLLM serve flags (per-model in `llama-swap.yaml`)

Both 35B-A3B MoE and 27B dense models use vLLM XPU with these shared flags:

- `--quantization gptq --dtype float16` — GPTQ-Int4 weights, FP16 compute
- `--kv-cache-dtype fp8` — FP8 KV cache, ~2× context capacity vs f16.
  Essential for the 35B's 256K context target.
- `--gpu-memory-utilization 0.93` — headroom for SYCL runtime, PyTorch
  allocator, and vLLM engine overhead. Both models are hybrid GDN/linear
  attention (`full_attention_interval: 4` — only 1 in 4 layers holds a real
  KV cache), so the effective KV footprint per token is small and 0.93
  leaves generous headroom.
- `--enable-prefix-caching` — APC for prompt reuse (code, structured output)
- `--enable-auto-tool-choice` — on both models
- `--reasoning-parser qwen3` — parses `<think>...</think>` out of the
  Qwen3.6/3.8 chat template into the OpenAI-compatible `reasoning_content`
  field instead of leaving it inline in `content`. Without this flag,
  clients that render `reasoning_content` separately (e.g. OpenCode,
  Open WebUI) see raw `<think>` tags in the response body.
- `--speculative-config MTP3` — Multi-Token Prediction with 3 speculative
  tokens. MTP3 is used — position-4 acceptance is weak (13–40%), making 3 tokens the balance point
  balances acceptance rate vs verification cost.
- `--max-num-seqs 4 --max-num-batched-tokens 4096` — concurrency budget.
  `max-num-seqs` is a scheduler admission cap, not a hard rejection limit:
  requests beyond it queue (`vllm:num_requests_waiting_by_reason{reason="capacity"}`)
  rather than erroring. vLLM reports `kv_cache_max_concurrency` (via the
  `vllm:cache_config_info` metric) as the number of _full-length_
  (`max-model-len`) sequences the KV pool can hold simultaneously — on the
  35B at 256K/fp8/0.93 util this is a single-digit figure. Since most real
  requests use far less than the full context window, `--max-num-seqs 4` fits
  comfortably in practice; the worst case under sustained full-context load
  is preemption and prefill recompute (a throughput cost), not an OOM or
  crash.

Per-model specifics:

- **35B-A3B (vision)**: `--max-model-len 262144` (256K),
  `--tool-call-parser qwen3_coder`. The MoE's ~2.3B activated params per
  token make it fast to decode but expensive to spec-decode (expert union on
  verify batch). MTP3 + fp8 KV + 0.93 util fits comfortably in 32 GB.
- **27B dense**: `--tool-call-parser qwen3_xml`, `--max-model-len 194560`
  (190K). The dense model is simpler (no expert routing) and runs alongside
  the 35B at the same context window.

### MTP Speculative Decoding (vLLM)

MTP replaces the old llama.cpp n-gram speculation. The cookbook's
`patch_mtp_nightly.py` gates unquantized draft MoE/linear layer construction
on `B70_MTP_BF16_DRAFT=1`. Additional patches applied at build time:

- `patch_mtp_boundary.py` — handles partial final speculative groups at
  max-model-len boundaries (XPU GDN kernel requirement)
- `patch_gdn_mixed_split_v5.py` — splits spec/non-spec tokens for the
  fused GDN attention kernel (causal_conv1d exclusive on spec XOR non-spec)
- `patch_fix_accepted_sync.py` — ports vllm#53919 (num_accepted_tokens D2H
  race condition, fail-closed)
- `patch_fix_backward_copy.py` — guards against destructive Mamba state
  backward copies (vllm#53505, fail-closed)
- `patch_fix_eagle_drop.py` — ports vllm#48375 (EAGLE/MTP cache pollution,
  fails closed)

See the [Cookbook image patch matrix](https://github.com/SergiioB/intel-arc-pro-b70-inference-cookbook)
for SHA-256 hashes of each patch against the f01e24f6 vllm source.

> Measured acceptance rates and decode throughput from this MTP configuration
> are in [Measured Performance (2026-09-10)](#measured-performance-2026-09-10)
> below.

### SYCL / Level Zero env

Same env vars as the llama.cpp era — `ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE`,
`GGML_SYCL_ENABLE_GRAPH=1` for llama-server children. vLLM itself uses
`VLLM_TARGET_DEVICE=xpu`, `VLLM_XPU_ENABLE_XPU_GRAPH=1`, and
`PYTORCH_ALLOC_CONF=expandable_segments:True` for memory management.

`SYCL_CACHE_PERSISTENT=0` — not enabled (causes hard crash at SYCL init,
bisected: graph-only boots clean, cache-only fails).

## Measured Performance (2026-09-10)

> **Node:** gpu-1 (2× Intel Arc Pro B70, 32 GB each, Ryzen 5 3600 host).
> **Config:** llama-swap + vLLM 0.28.1rc1, GPTQ-Int4, `--kv-cache-dtype fp8`,
> MTP speculative decoding (`num_speculative_tokens: 3`). 35B runs on GPU-0,
> 27B on GPU-1 — they are never colocated, so cross-model comparisons below
> are cross-GPU/cross-time, not a controlled head-to-head.

### 27B Dense (GPU-1)

Session 1 (fresh, GPU KV cache 25–43%, prefix cache climbing 47–53%):

| Metric                     | Value           |
| -------------------------- | --------------- |
| Mean gen throughput        | ~40 tok/s       |
| Range (clean decode)       | 31.5–59.5 tok/s |
| Mean MTP acceptance length | ~3.15           |
| Avg draft acceptance rate  | 55.2%           |

Session 2 (deeper into the same conversation, GPU KV cache 77–81%, prefix cache steady ~50%):

| Metric                     | Value           |
| -------------------------- | --------------- |
| Mean gen throughput        | ~44 tok/s       |
| Range (clean decode)       | 31.8–57.5 tok/s |
| Mean MTP acceptance length | ~3.77           |
| Avg draft acceptance rate  | 69.3%           |

**Key findings:**

- **No degradation through 81% KV cache utilization** — throughput and MTP
  acceptance were both slightly _higher_ in session 2 despite heavier KV
  pressure. A 91–99% acceptance streak (4 consecutive windows) pulled decode
  to 54–57.5 tok/s. This is evidence that **MTP acceptance rate, not KV
  pressure or raw compute, is the dominant swing factor** in decode
  throughput on this hardware. Behavior above ~90% KV utilization (near
  eviction/exhaustion) remains untested.
- **The ~2–2.5× improvement over pre-MTP llama.cpp comes from MTP itself:**
  the vLLM engine swap alone (same XPU backend, same GPTQ quant, no MTP) is
  roughly a wash with the old llama.cpp Vulkan decode (~18–22 tok/s
  estimated vs 8–25 tok/s measured). MTP3's mean acceptance length of ~3.15
  means ~3 tokens land per target-model forward pass — a ~3×
  tokens-per-forward-pass multiplier that the smaller MTP draft-head cost is
  cheap enough to justify.

### 35B-A3B MoE (GPU-0)

> Small sample: n=3–4 true clean-decode (`prompt=0`) windows in the measured
> session (n=25 total non-idle windows). Numbers below are directional, not
> final.

| Metric                                        | Value                            |
| --------------------------------------------- | -------------------------------- |
| Mean gen throughput (excl. 1 short turn, n=3) | ~72 tok/s (54.6–87.8)            |
| Mean gen throughput (incl. short turn, n=4)   | ~55 tok/s (6.7–87.8)             |
| Peak observed (lightly diluted window)        | 112.2 tok/s                      |
| Mean MTP acceptance length (all 25 windows)   | ~3.39                            |
| Avg draft acceptance rate (all 25 windows)    | ~59.8%                           |
| Prefix cache hit rate                         | climbed 0% → 87.8% over session  |
| GPU KV cache usage                            | 13–30% (well below 27B's 25–81%) |

### MoE vs Dense

| Metric                     | 27B Dense (both sessions) | 35B-A3B MoE                        |
| -------------------------- | ------------------------- | ---------------------------------- |
| Clean decode throughput    | 31.5–59.5 (avg ~40–44)    | 54.6–87.8 (avg ~55–72), peak 112.2 |
| Mean MTP acceptance length | 3.15–3.77                 | ~3.39                              |
| Avg draft acceptance rate  | 55.2–69.3%                | ~59.8%                             |
| GPU KV cache usage         | 25–81%                    | 13–30%                             |
| Prefix cache hit rate      | 47–53% → steady 50%       | climbed to 87.8%                   |

**Takeaway:** the 35B MoE (≈2.3B active params/token) decodes ~1.5–2× faster
than the 27B dense model despite being the larger checkpoint — consistent
with MoE sparsity keeping per-token compute low. It also uses noticeably less
GPU KV cache for the same conversation style. MTP acceptance is in the same
ballpark as 27B (~55–70% draft acceptance across all data), so the
throughput gap comes from the base model's per-forward-pass cost, not a
materially different MTP hit rate.

### MTP Per-Position Acceptance

Per-position acceptance decays with draft depth — the expected pattern for a
speculative-decoding head:

| Position | Typical acceptance      |
| -------- | ----------------------- |
| 1        | 0.75–0.85               |
| 2        | 0.47–0.66               |
| 3        | 0.25–0.54               |
| 4        | 0.13–0.70 (often <0.50) |

Position-4 acceptance is often very low (0.13–0.40, one instance of 0.000).
Drafting 4 tokens when the 4th almost never lands means ~1/4 of the draft
forward passes are near-waste — `num_speculative_tokens: 3` vs `4` is a
low-cost tuning lever worth testing.

### SaaS Comparison

| GPU         | Backend                      | Model              | Decode t/s             | Source                          |
| ----------- | ---------------------------- | ------------------ | ---------------------- | ------------------------------- |
| Arc Pro B70 | vLLM XPU FP16 (no MTP, TP=4) | Qwen3.6-35B-A3B    | 16.3                   | Puget Systems                   |
| Arc Pro B70 | vLLM XPU FP16 (no MTP, TP=4) | Qwen3.6-27B        | 13.1                   | Puget Systems                   |
| Arc Pro B70 | **vLLM XPU + MTP3**          | Qwen3.8-27B (GPTQ) | ~40–44 avg (31.5–59.5) | HomeLab (GPU-1, two sessions)   |
| Arc Pro B70 | **vLLM XPU + MTP3**          | Qwen3.6-35B-A3B    | ~55–72 avg (6.7–112.2) | HomeLab (GPU-0, single session) |

Puget Systems' figures use tensor-parallelism across 4 GPUs with no
speculative decoding. HomeLab's single-GPU MTP setup reaches ~3× Puget's
27B figure and ~4× its 35B figure — attributable to MTP speculative decoding
plus the absence of TP/cross-card communication overhead.

### Known Gaps

1. **Position-4 MTP acceptance is weak** (often 0.13–0.40, one 0.000).
   Testing `num_speculative_tokens: 3` vs `4` is the obvious tuning lever.
2. **No long-running decay test yet** — sessions measured were ~4–5 minutes.
   Session 2 showed no decay through 77–81% KV cache, but a 30+ minute
   session is needed to characterize decode decay near KV exhaustion.
3. **35B-A3B sample is small** — only 3–4 true clean-decode windows measured.
   Numbers are directional; need a longer dedicated 35B session for
   confidence.
4. **Concurrency untested** — only single-stream tested (`--max-num-seqs 4`,
   1 running req). Multi-stream throughput is unmeasured.
5. **No Prometheus percentiles** — data above is from 10-second-window
   averages in vLLM engine logs. True p50/p99/p999 inter-token latency would
   require querying the vLLM `/metrics` endpoint directly.
6. **Speculative quality tradeoff unverified** — MTP uses a smaller draft
   model (usually quantized/truncated). Need to verify output quality is not
   degraded vs the base model (human eval or benchmark comparison).
7. **SYCL-era vs vLLM throughput measurement gap (open).** The 2026-08-18
   llama.cpp SYCL migration recorded 862–1230 t/s via llama-swap's Activity
   "Gen Speed" column; the vLLM + MTP numbers above (~40–72 tok/s) are
   10-second-window means from the vLLM engine log. These are different
   measurement methods and are **not directly comparable** — reconciling the
   apparent ~20× gap is an open question, not a confirmed regression.

## Memory model

This section describes the measured breakdown of RAM and VRAM usage across
the llama-swap pod lifecycle. vLLM models allocate weights + KV cache in VRAM
at load time; host RAM is used for the PyTorch allocator staging area and
SYCL runtime buffers.

### Per-GPU VRAM (static at load)

VRAM usage is fixed at load and does not grow with session activity. The total
includes weights, KV cache, and vLLM engine overhead:

| Model               | Weights   | KV cache (fp8) | Headroom  |
| ------------------- | --------- | -------------- | --------- |
| 35B-A3B (256K)      | ~23.4 GiB | ~4.8 GiB       | ~3.8 GiB  |
| 27B (190K)          | ~18.2 GiB | ~2.9 GiB       | ~9.8 GiB  |
| embed-spread (120K) | ~0.4 GiB  | ~0.5 GiB       | ~31.1 GiB |

> Figures are approximate and predate the `--gpu-memory-utilization 0.93`
> tuning pass; the ratios (weights dominate, KV cache is small relative to
> weights on both hybrid GDN models) still hold. Query
> `vllm:cache_config_info` on the model's proxied `/metrics` endpoint for
> exact live `kv_cache_size_tokens` and `kv_cache_max_concurrency`.

VRAM headroom accounts for SYCL runtime (~1–2 GB) and vLLM engine overhead
(tokenizer, scheduler, KV cache manager). If the pod OOMs on model load or
pushes VRAM over 32 GB, reduce `--gpu-memory-utilization`, `--max-num-batched-tokens`, or `--max-model-len`.

### Host RAM (anonymous, per-instance)

| Component                                       | Size       | Behavior                                                                                      |
| ----------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------- |
| Baseline (SYCL/Level-Zero runtime, vLLM engine) | ~2–4 GiB   | Allocated at load, stays flat                                                                 |
| PyTorch staging buffers                         | 0 → ~8 GiB | climbs with session load, plateaus                                                            |
| Freed on unload                                 | yes        | When the child process is killed (model swap), all anonymous memory is returned to the cgroup |

### Summary

- VRAM: static ~22–24 GiB per GPU for chat models at load. No spillover.
- Host anonymous: bounded by usage high-water mark; freed on model unload.

## GPU Backend: SYCL (not Vulkan)

llama-swap uses Intel's SYCL/Level Zero backend for both llama.cpp
(embedding models) and vLLM (chat models). Device targeting differs by
engine:

- **llama.cpp (`embed-spread`)**: `ONEAPI_DEVICE_SELECTOR=level_zero:0,1`
  — llama.cpp honors this var directly to pick/limit visible devices.
- **vLLM (`35b-*` / `27b-*`)**: `ZE_AFFINITY_MASK=0` or `=1` only.
  `ONEAPI_DEVICE_SELECTOR` is **not** set for vLLM models — verified it has
  no effect on `torch.xpu.device_count()` or device selection at all.
  vLLM's `XPUPlatform.device_control_env_var` is `ZE_AFFINITY_MASK`; vLLM
  re-translates logical↔physical device IDs through this var itself
  (`vllm/platforms/interface.py`), so it's the only lever that actually
  works, and the only one vLLM expects to own.

Chat models run on vLLM XPU (`VLLM_TARGET_DEVICE=xpu`) — the same SYCL/Level
Zero path via PyTorch/XPU. No Mesa/Vulkan userspace is needed.

### Image tag

The custom image is
`registry.arthurvardevanyan.com/homelab/llama-swap:v255-intel-b10868-<sha>` —
the tag encodes the llama-swap version (`v255`), the vLLM XPU base image
build (`intel-b10868`), and a short commit SHA of the containerfile/patches.
Renovate-managed; the PaC build (Tekton) pushes on PR merge.

### Preload times

vLLM cold starts include: SYCL context init (~15 s), model weight loading
(~60–90 s), and engine warm-up (~30–60 s). Total: ~120–180 s. Embedding
models (llama.cpp) load in ~45–90 s.

Confirm the SYCL backend from inside the pod:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm exec deploy/llama-swap -- /app/llama-server --help 2>&1 | grep -iE "sycl|level.zero|ze"
# or, from a debug pod with gpu.intel.com/xe request:
xpu-smi stats -d 0
clinfo | grep -i "Device Name"
```

## Scaling

For higher throughput:

- **Dual** (`dual_35b`, `dual_27b`): one model per GPU, same family, both
  GPUs always required. Provides redundancy and doubles throughput for
  concurrent requests.
- **Mixed dual** (`dual_35b0-27b1`, `dual_27b0-35b1`): 35B on one GPU + 27B
  on the other, for maximum flexibility without full-model loading.
- **Embed spread** (`dual_35b-spread`, `dual_27b-spread`,
  `dual_35b0-27b1-spread`, `dual_27b0-35b1-spread`): chat models on both
  GPUs + embedding model spread across both GPUs (~2 GB total). Embed runs
  alongside chat. **Currently commented out of `matrix.sets`** — see the
  `embed-spread` note in [Model Matrix](#model-matrix).
- **Embed spread standalone** (`embed_spread`): embed-only mode when no chat
  is needed. **Currently commented out of `matrix.sets`**, same reason.
- **Multiple llama-swap replicas** with a LoadBalancer: add replicas in
  `overlays/okd/llama-swap.yaml` and expose via a LoadBalancer service.
  llama-swap's config matrix handles the shared hardware — no external
  orchestrator needed for GPU-aware scheduling.
- **Horizontal Pod Autoscaler** (HPA): not yet configured. With
  `--max-num-seqs 4` per chat model, the current setup handles concurrent
  requests well. Add HPA once load patterns are measured.

`hooks.on_startup.preload` is currently commented out in `llama-swap.yaml`
(no models load automatically at boot); the matrix solver loads a set
on-demand from the first request. When re-enabled, embed-spread stays
resident once a `-spread` set is chosen (evict_cost 1 vs chat models
10–20); if only chat-only sets are active, embed may be evicted by the
solver but reloads via TTL (300s) when needed.

## Metrics

llama-swap exposes **proxy-level** Prometheus metrics on `/metrics` (port 8080).
For chat models (vLLM), token-throughput metrics come from the vLLM
`/metrics` endpoint on the child process's own ephemeral upstream port
(assigned per-model by llama-swap, not fixed). Embedding models (llama.cpp)
still expose `llamacpp:*` metrics via the metrics-exporter sidecar on port 9100.

### Proxy metrics

| Metric                          | Type    | Description                                              |
| ------------------------------- | ------- | -------------------------------------------------------- |
| `llamaswap_cpu_util_percent`    | Gauge   | CPU utilization per core (0–100)                         |
| `llamaswap_memory_used_bytes`   | Gauge   | Used system memory (bytes)                               |
| `llamaswap_memory_total_bytes`  | Gauge   | Total system memory (bytes)                              |
| `llamaswap_load_average`        | Gauge   | Load average (labels: 1m, 5m, 15m)                       |
| `llamaswap_network_bytes_total` | Counter | Network bytes transferred (labels: interface, direction) |

### Embedding model metrics (llama.cpp, via metrics-exporter sidecar)

The metrics-exporter sidecar discovers active embedding models by polling
`GET /running` on the llama-swap API every 10s, scrapes each llama-server
child's `/metrics` endpoint, and re-exposes aggregated series on port 9100:

| Metric                            | Type    | Description                      |
| --------------------------------- | ------- | -------------------------------- |
| `llamacpp:prompt_tokens_total`    | Counter | Prompt tokens processed          |
| `llamacpp:tokens_predicted_total` | Counter | Generation tokens processed      |
| `llamacpp:n_tokens_max`           | Counter | High-watermark context size seen |
| `llamacpp:requests_processing`    | Gauge   | Requests currently processing    |
| `llamacpp:requests_deferred`      | Gauge   | Requests deferred (queued)       |

Chat model metrics (vLLM) are exposed on the child process's own ephemeral
port and can be scraped via the llama-swap proxy:
`GET http://127.0.0.1:8080/upstream/<model-id>/metrics` — vLLM's `/metrics`
endpoint is proxied through llama-swap when the model is loaded. Includes
`vllm:cache_config_info` (KV cache size, `kv_cache_max_concurrency`,
`gpu_memory_utilization`) and `vllm:num_requests_waiting_by_reason`
(`capacity` = waiting for a free `max-num-seqs` slot, `deferred` = blocked
by other transient constraints).

## References

- [vLLM](https://github.com/vllm-project/vllm)
- [llama-swap](https://github.com/llama-swap/llama-swap)
- [Intel Arc B70 Inference Cookbook](https://github.com/SergiioB/intel-arc-pro-b70-inference-cookbook)
- [Intel Level Zero](https://github.com/oneapi-src/level-zero)
- [75 t/s on a single B70 (Reddit)](https://www.reddit.com/r/IntelArc/comments/1u3l4zx/qwen3635ba3b_at_75_tokens_per_second_on_a_single/)
- [Puget Systems — Multi-GPU B70 inference](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/) — vLLM XPU TP=4 baseline (no MTP), cited in [SaaS Comparison](#saas-comparison)
