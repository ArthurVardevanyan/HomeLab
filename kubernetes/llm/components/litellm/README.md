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
    - [Router settings](#router-settings)
    - [Response \& cache](#response--cache)
    - [GPU affinity plugin](#gpu-affinity-plugin)
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
`/v1/chat/completions` requests, LiteLLM authenticates the caller via Zitadel
OIDC, tracks token-level cost, routes the request to the appropriate GPU via the
`llama_swap_affinity.py` plugin, and returns a streaming response in OpenAI
format.

Two public model aliases are exposed (`qwen3.6-35b-a3b`, `qwen3.6-27b`),
each with two GPU-backed deployments (gpu0 and gpu1).
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

Three model names are exposed to clients, each with two deployments (one per
GPU) for load-aware routing:

| Public alias      | GPU 0 deployment  | GPU 1 deployment  | Input cost/token | Output cost/token |
| ----------------- | ----------------- | ----------------- | ---------------- | ----------------- |
| `qwen3.6-35b-a3b` | `openai/35b-gpu0` | `openai/35b-gpu1` | 1.86e-6          | 1.24e-6           |
| `qwen3.6-27b`     | `openai/27b-gpu1` | `openai/27b-gpu0` | 3.98e-6          | 2.65e-6           |

All deployments point to `http://llama-swap-svc.llm.svc.cluster.local:8080/v1`
with `api_key: "dummy"`. Cost tracking is enabled via `SPEND_TRACKING: "true"`
and `store_prompts_in_spend_logs: true` — token usage is stored in the CNPG
PostgreSQL database.

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

LiteLLM uses **Dragonfly** (`litellm-dragonfly.llm.svc.cluster.local:6379`) as
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

- **Connection**: `postgresql://postgres@litellm-rw.llm.svc.cluster.local:5432/litellm`
  (via the CNPG read-write service).
- **`STORE_MODEL_IN_DB: false`**: models are defined in `litellm.yaml`, not
  fetched from the database.
- **`store_prompts_in_spend_logs: true`**: prompt content is included in the
  spend tracking logs for cost attribution.

## References

- [LiteLLM](https://github.com/berriai/litellm)
