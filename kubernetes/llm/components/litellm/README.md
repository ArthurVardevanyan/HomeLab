# LiteLLM (API Gateway)

LiteLLM acts as the API gateway between Open WebUI and llama-swap, providing
routing with GPU affinity via a custom `llama_swap_affinity` plugin.

## Table of Contents

- [LiteLLM (API Gateway)](#litellm-api-gateway)
  - [Table of Contents](#table-of-contents)
  - [Architecture](#architecture)
  - [Configuration](#configuration)
    - [`litellm.yaml`](#litellmyaml)
    - [Public model aliases](#public-model-aliases)
    - [Pricing model](#pricing-model)
      - [Recomputing costs](#recomputing-costs)
    - [Router settings](#router-settings)
    - [Response \& cache](#response--cache)
    - [GPU affinity plugin](#gpu-affinity-plugin)
      - [KV cache efficiency](#kv-cache-efficiency)
  - [Deployment](#deployment)
  - [OIDC / SSO](#oidc--sso)
  - [Metrics](#metrics)
  - [Storage](#storage)
  - [Database](#database)
  - [References](#references)

## Architecture

```txt
Open WebUI → LiteLLM (Zitadel OIDC + cost tracking) → llama-swap → llama-server (GPU 0 or GPU 1)
```

LiteLLM acts as an **OpenAI API compatibility proxy**: Open WebUI sends standard
`/v1/chat/completions` and `/v1/embeddings` requests, LiteLLM authenticates the
caller via Zitadel OIDC, tracks token-level cost, routes the request to the
appropriate GPU via the `llama_swap_affinity.py` plugin, and returns a streaming
response in OpenAI format.

Five public model aliases are exposed: three with two deployments (gpu0 and gpu1)
for load-aware routing, one spread model using both GPUs, and one embedding model
with two GPU-backed deployments.
LiteLLM's routing plugin narrows the candidate list using llama-swap's ground
truth (which models are resident on which GPU), then picks the least busy slot
when both GPUs have the model loaded.

LiteLLM also provides **response caching** (via Dragonfly Redis-compatible
cache, 24h TTL) and **cost tracking** (per-model input/output cost per token,
stored in PostgreSQL via CNPG).

## Configuration

### `litellm.yaml`

The LiteLLM configuration (`components/litellm/litellm.yaml`) is mounted as a
ConfigMap at `/etc/litellm/litellm.yaml` (read-only). It defines two public
model aliases, each backed by two GPU deployments, along with routing, caching,
and cost-tracking settings.

### Public model aliases

Four model names are exposed to clients: three with two deployments (one per GPU) for load-aware routing, and one spread model using both GPUs.

| Public alias             | GPU 0 deployment        | GPU 1 deployment        | Input cost/token | Output cost/token |
| ------------------------ | ----------------------- | ----------------------- | ---------------- | ----------------- |
| `qwen3.6-35b-a3b`        | `openai/35b-gpu0`       | `openai/35b-gpu1`       | 1.3e-8           | 1.3e-8            |
| `qwen3.6-35b-a3b-dense`  | `openai/35b-gpu0-dense` | `openai/35b-gpu1-dense` | 1.3e-8           | 1.3e-8            |
| `qwen3.8-27b`            | `openai/27b-gpu1`       | `openai/27b-gpu0`       | 1.3e-8           | 1.3e-8            |
| `qwen3.6-35b-a3b-spread` | `openai/35b-spread`     | —                       | 0.8e-8           | 0.8e-8            |

All deployments point to `http://llama-swap-svc.llm.svc.cluster.local.:8080/v1`
with `api_key: "dummy"`. Cost tracking is enabled via `SPEND_TRACKING: "true"`
and `store_prompts_in_spend_logs: true` — token usage is stored in the CNPG
PostgreSQL database.

### Pricing model

Costs are based on actual wall-plug electricity consumption measured against
token throughput. For the current methodology, see
[`notes/power.log`](../../../notes/power.log) (smart plug data) and the
recomputation procedure below.

#### Recomputing costs

Run these queries against Thanos (or your Prometheus endpoint) for the target
period. Replace the time range as needed.

**1. Get the electricity rate from your utility bill.**
Extract the all-in effective rate (energy charges + PSC + PSCR). For the August
2026 computation:

```log
Off-Peak energy:   $0.028780/kWh
Mid-Peak energy:   $0.055790/kWh
On-Peak energy:    $0.108000/kWh
PSC (MI):          $0.097260/kWh
PSCR:              $0.018770/kWh

All-in (mid-peak baseline): ~$0.227/kWh
```

**2. Get total tokens from LiteLLM:**

```promql
# Total input tokens
sum(increase(litellm_input_tokens_metric_total{model=~".+"}[30d]))

# Total output tokens
sum(increase(litellm_output_tokens_metric_total{model=~".+"}[30d]))
```

**3. Get total smart plug energy for the period:**

The smart plug sensor is `sensor.kvm_7_current_consumption` in Home Assistant.
Data is logged to `notes/power.log` at 1-minute intervals. Compute energy:

```bash
# Count idle vs active readings (idle < 120W, active ≥ 120W)
awk -F, 'NR>1 && $2 < 120 {idle++; total++} NR>1 {total++}
         END {print "Idle:", idle, "Active:", total-idle, "Total:", total}' notes/power.log

# Sum power values to get kWh
awk -F, 'NR>1 {sum += $2} END {printf "Total Wh: %g, kWh: %g\n", sum, sum/1000}' notes/power.log

# Split idle vs active energy
awk -F, 'NR>1 {
    if ($2 < 120) idle_sum += $2; else active_sum += $2;
    total++
}
END {
    hours_per_reading = 1.0/60.0
    printf "Idle: %.1f kWh\nActive: %.1f kWh\nTotal: %.1f kWh\n",
        idle_sum * hours_per_reading / 1000,
        active_sum * hours_per_reading / 1000,
        total * hours_per_reading / 1000
}' notes/power.log
```

**4. Compute per-token cost:**

```log
Total tokens = input_tokens + output_tokens
Total cost = total_kWh × effective_rate
$/token = total_cost / total_tokens
```

For the August 2026 data:

- 64.0 kWh total × $0.227/kWh = $14.53
- 1.136B total tokens (1.128B input + 8.24M output)
- **$0.0000000128/token ≈ $0.013/1M tokens**

**5. Model-specific adjustments:**

The base rate applies equally to all models since they share the same hardware.
Adjust for models with different throughput characteristics:

- **Spread model**: parallel processing across both GPUs provides ~30-40%
  throughput improvement → multiply base rate by 0.6
- **Dense vs MoE**: if hardware configuration differs (different GPUs, power
  limits), recalculate using the same procedure

**6. Update files:**

- `kubernetes/llm/components/litellm/litellm.yaml` — `input_cost_per_token` and
  `output_cost_per_token` for each model alias
- `machineConfigs/desktop/home/arthur/.config/opencode/opencode.json` — `cost`
  fields (in $/1M tokens, not $/token)
- This README — pricing table values

The smart plug data is collected via Home Assistant (`sensor.kvm_7_current_consumption`)
and written to `notes/power.log` every minute. Ensure the sensor is on the same
circuit as the LLM system (gpu-1 node) for accurate readings.

### Router settings

- **`routing_strategy: least-busy`** — baseline strategy; superseded by the GPU
  affinity plugin for the models it covers (see below).
- **`cache_responses: true`** — caches API responses in Dragonfly for repeated
  requests.
- **`plugins: [llama_swap_affinity.plugin]`** — the custom routing plugin
  (mounted at `/etc/litellm/llama_swap_affinity.py` alongside `litellm.yaml`).
  Resolved via the dotted-path convention (`litellm.proxy.types_utils.utils.get_instance_fn`).
- **`disable_cooldowns: true`** — required by the plugin: if a deployment the
  plugin narrows to were ever dropped via LiteLLM's failure-count cooldown, the
  intersection with `healthy_deployments` would be empty and the request would
  hard-fail instead of falling back. All deployments here are one llama-swap pod
  on one node, so llama-swap's own process state (which the plugin already reads)
  is a more accurate health signal than LiteLLM's 3-failures/5-second cooldown.
- **`health_check_interval: 300`** — backend health check period (seconds).
- **`store_model_in_db: false`** — models are defined in config, not the database.
- **`user_api_key_cache_ttl: 300`** — user API key validation cache TTL (seconds).
- **`user_header_mappings`** — maps the `X-OpenWebUI-User-Email` header to the
  `customer` role for cost attribution.

### Response & cache

LiteLLM uses **Dragonfly** (`litellm-dragonfly.llm.svc.cluster.local.:6379`) as
a Redis-compatible cache backend:

- **Response caching**: `cache: true` with `ttl: 86400` (24 hours), namespace
  `litellm-proxy`. Enabled via `cache_params` in `litellm_settings`.
- **User API key cache**: `user_api_key_cache_ttl: 300` (5 minutes) for
  validating API key lookups.
- **Authentication**: `enable_redis_auth_cache: true` — Dragonfly requires auth.

### GPU affinity plugin

`llama_swap_affinity.py` implements custom routing logic by overriding LiteLLM's
built-in `least-busy` counter for the two model groups. It narrows the
candidate list using llama-swap's ground truth:

1. **Cold start** (no candidate is resident): leave the candidate list untouched.
   The GPU-preference ordering in `litellm.yaml`'s model_list decides which GPU
   gets loaded first.
2. **One resident**: narrow to it. Every model runs with `ttl: 0` (never expires),
   so if only one copy is loaded, the other GPU is almost certainly serving a
   different model — routing there would force an unnecessary eviction.
3. **Both ready**: check for session stickiness first, then fall back to
   least-busy slot selection:
   - **Session stickiness**: the plugin computes a sha256 fingerprint from the
     model name and the first user message content (truncated to 500 chars), then
     looks up an in-memory pin map. If a valid pin (not expired, 1h TTL) exists
     and the pinned GPU is ready, the request is routed there to keep the
     conversation's KV cache hot. If the pinned GPU is not ready, it falls back
     to least-busy and creates a new pin. The pin map has an LRU eviction cap of
     10,000 entries.

   - **Least-busy**: when no pin applies, poll llama.cpp's per-instance `/slots`
     endpoint (proxied through `llama-swap-svc:8080/upstream/<model>/slots`) for
     actual busy-slot counts, route to whichever has fewer busy slots. Ties are
     broken with a round-robin counter — this is what fixes the observed skew
     where LiteLLM's built-in counter always chose the first-listed deployment.

The plugin caches `/running` (1s TTL) and `/slots` (0.25s TTL) to avoid
hammering llama-swap during request bursts. HTTP calls use a 1s timeout; on
failure, the plugin fails open (returns candidates unmodified) so a llama-swap
hiccup never blocks routing.

The `/slots` poll is proxied through llama-swap's `upstream.ignorePaths` guard
(see `llama-swap.yaml`) which prevents the path from ever triggering a model
load/swap — defense-in-depth against a bug in the plugin doing otherwise.

#### KV cache efficiency

Session stickiness preserves llama.cpp's per-instance KV cache across consecutive
turns in the same conversation. Without it, the round-robin tie-break caused each
turn to alternate GPUs, evicting and rebuilding the KV cache on every request.

The llama-swap Grafana dashboard's **Efficiency** row now includes panels for:

- **KV Cache Hit Ratio %**: estimated as `1 - (llamacpp:prompt_tokens_total /
litellm_input_tokens_metric_total)` — the fraction of input tokens served from
  KV cache rather than re-processed by the model.
- **KV Cache Reused Tokens**: estimated rate of tokens served from cache
  (input_tokens − prompt_tokens_processed).
- **Prompt Processing Ratio**: ratio of llama.cpp prompt tokens to LiteLLM input
  tokens. A lower ratio indicates more cache reuse.

Note: these are estimates because LiteLLM counts all API input tokens
(system messages, tool calls, etc.) while llama.cpp only counts tokens actually
processed by the model. Direct `cached_tokens` metrics from llama.cpp's
`usage.prompt_tokens_details.cached_tokens` are not exposed via the
llama-cpp-exporter's Prometheus metrics endpoint.

## Deployment

LiteLLM is deployed as a single-replica Deployment in the `llm` namespace,
scheduled on the GPU node (`gpu-1`) via `nodeSelector`:

- **Image**: `ghcr.io/berriai/litellm:v1.96.2` (Renovate-managed).
- **Strategy**: `RollingUpdate` (1 replica, no downtime during rollout).
- **Resources**: 250m–1 CPU, 1Gi–3Gi memory, 128Mi–512Mi ephemeral storage.
  VPA (InPlaceOrRecreate) maintains a 50m CPU / 256Mi memory floor.
- **Probes**: startup probe on `/health/liveliness` (60×10s), liveness on the
  same path (30s, 5 failures), readiness on `/health/readiness` (15s, 3 failures).
- **Termination**: 30s grace period.
- **Volumes**: config (`litellm-config` ConfigMap, read-only) mounted at
  `/etc/litellm` (contains `litellm.yaml` and `llama_swap_affinity.py`).
- **Service account**: minimal permissions, `automountServiceAccountToken: false`.
- **Security**: non-root, dropped capabilities (`ALL`), `RuntimeDefault`
  seccomp profile, no privilege escalation.

The deployment is a separate ArgoCD application from llama-swap, with its own
`kustomization.yaml` composing base + component manifests.

## OIDC / SSO

LiteLLM uses **Zitadel** as the OIDC provider (same IdP used across the
homelab). Configuration is provided via environment variables in the deployment:

| Variable                         | Source                                            | Value                                                      |
| -------------------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| `GENERIC_CLIENT_ID`              | `litellm-config` secret (`GENERIC_CLIENT_ID`)     | —                                                          |
| `GENERIC_CLIENT_SECRET`          | `litellm-config` secret (`GENERIC_CLIENT_SECRET`) | —                                                          |
| `GENERIC_AUTHORIZATION_ENDPOINT` | env var                                           | `https://zitadel.arthurvardevanyan.com/oauth/v2/authorize` |
| `GENERIC_TOKEN_ENDPOINT`         | env var                                           | `https://zitadel.arthurvardevanyan.com/oauth/v2/token`     |
| `GENERIC_USERINFO_ENDPOINT`      | env var                                           | `https://zitadel.arthurvardevanyan.com/oidc/v1/userinfo`   |
| `GENERIC_SCOPE`                  | env var                                           | `openid profile email`                                     |
| `GENERIC_USER_ID_ATTRIBUTE`      | env var                                           | `sub`                                                      |
| `GENERIC_USER_EMAIL_ATTRIBUTE`   | env var                                           | `email`                                                    |
| `PROXY_BASE_URL`                 | env var                                           | `https://litellm.arthurvardevanyan.com`                    |
| `LITELLM_MASTER_KEY`             | `litellm-config` secret (`LITELLM_MASTER_KEY`)    | —                                                          |

The `X-OpenWebUI-User-Email` header from Open WebUI is mapped to the `customer`
role via `user_header_mappings`, enabling per-user cost tracking.

The LiteLLM proxy is exposed externally at `litellm.arthurvardevanyan.com` via
a Gateway API HTTPRoute (in `components/litellm-gateway/`).

## Metrics

LiteLLM exposes Prometheus metrics via the `prometheus` callback. The
`require_auth_for_metrics_endpoint: false` setting allows unauthenticated
access to `GET /metrics`. A `ServiceMonitor` scrapes the proxy on port 4000.

The Prometheus scrape job is defined in the combined `llm` job alongside
llama-swap and intel-gpu metrics (see the main README's [Metrics](../README.md#metrics)
section).

## Storage

LiteLLM does **not** use local disk for persistent state — it is a stateless
proxy. All state (cache, sessions, cost tracking) is external:

- **Response cache**: Dragonfly Redis-compatible cache (`litellm-dragonfly`,
  24h TTL, in-memory).
- **Database**: PostgreSQL via CNPG (`litellm-rw`, see below).
- **Stateless**: no `litellm-state-pvc` exists — the component directory does
  not define any PVC for LiteLLM. The deployment's root filesystem is writable
  only for the cache directory (`/root`), not for persistent data.

## Database

LiteLLM uses PostgreSQL for cost tracking, spend logs, and session data,
deployed via CloudNativePG (`components/cnpg-litellm/`):

- **Connection**: `postgresql://postgres@litellm-rw.llm.svc.cluster.local.:5432/litellm`
  (via the CNPG read-write service).
- **`STORE_MODEL_IN_DB: false`**: models are defined in `litellm.yaml`, not
  fetched from the database.
- **`store_prompts_in_spend_logs: true`**: prompt content is included in the
  spend tracking logs for cost attribution.

## Embedding Model

The `qwen3-embedding-4b` model runs on both GPUs through llama-swap, with
GPU 1 as primary and GPU 0 as fallback. The llama-swap matrix solver picks
the appropriate companion set:

- **GPU 1 idle, GPU 0 busy with chat**: `embed_35b0-1` or `embed_27b0-1` loads
  the embed model on GPU 1 alongside a chat model on GPU 0
- **GPU 0 idle, GPU 1 busy with chat**: `embed_35b1-0` or `embed_27b1-0` loads
  the embed model on GPU 0 alongside a chat model on GPU 1
- **Both GPUs busy with chat**: llama-swap evicts the lowest-cost model (embed,
  eviction cost 5) to free a GPU, or queues the request

LiteLLM routes embedding requests using a GPU residency check: when both GPUs
have the embed model loaded, it polls `/slots` for least-busy selection with
round-robin tie-breaking. The `/running` cache uses a 5s TTL to reduce HTTP
calls during bursts. No session stickiness (embeddings don't need KV cache reuse).

| Deployment         | RPM | Requests/sec | Parallel slots | Max concurrent in-flight   |
| ------------------ | --- | ------------ | -------------- | -------------------------- |
| `qwen3-embed-gpu1` | 960 | 16 r/s       | 32             | ~16 (16 r/s × ~1s/request) |
| `qwen3-embed-gpu0` | 960 | 16 r/s       | 32             | ~16 (16 r/s × ~1s/request) |

The 960 RPM (16 r/s) per deployment limit leaves headroom so llama-swap never
exceeds 50% of its 32-parallel capacity. With two GPUs, total capacity is
~32 r/s when both embeddings are loaded.

### Limitation: Open WebUI burst behavior

Open WebUI processes documents by splitting them into chunks (default 5000
characters) and sends all chunks to LiteLLM in a single burst. When multiple
files are uploaded simultaneously, the burst can temporarily exceed the per-GPU
capacity.

**What happens:**

1. Open WebUI sends 50-100 chunk requests at once
2. LiteLLM allows the first ~16 requests through per GPU (limited by RPM and
   parallel slots)
3. Remaining requests hit the rate limit and receive HTTP 429
4. Open WebUI displays these as "Request Failed" errors

**Mitigations:**

- With two GPUs loaded, total capacity is ~32 r/s (16 r/s per GPU)
- Multi-file syncs may show transient 429s for later files
- No client-side retry is implemented in Open WebUI (it shows the 429 error)
- No sidecar/queue is deployed (to avoid extra latency and complexity)

If 429s become problematic during large document batches, consider:

- Reducing Open WebUI's `CHUNK_SIZE` to decrease per-batch burst size
- Adding a proxy-side retry mechanism (nginx/envoy sidecar with 429 backoff)
- Increasing `rpm` if llama-swap's `--parallel` is raised in the future

## References

- [LiteLLM](https://github.com/berriai/litellm)
