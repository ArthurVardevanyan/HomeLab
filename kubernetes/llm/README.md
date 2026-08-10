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
  - [Open WebUI (chat front-end)](#open-webui-chat-front-end)
    - [Deployment](#deployment)
    - [OIDC / SSO](#oidc--sso)
    - [Database](#database)
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

### Image tag

The custom image tag is the upstream llama.cpp build number
(e.g. `b10331`). The pipeline extracts it from the containerfile's `FROM` tag
(single source of truth — the same tag is pinned in the initContainer image).
When Renovate proposes a bump in the containerfile (e.g. `b10331` →
`b10335`), PaC builds and pushes the new tag. On the next Renovate run
(weekly), the deployment is bumped to the new `tag@sha256:digest` reference.
This means the deployment typically lags the containerfile by up to one
Renovate cycle (~1 week). A containerfile-only rebuild under an unchanged tag
no longer rolls immediately — it rolls when the digest changes in git.

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
        "requests": {"gpu.intel.com/xe": "1"},
        "limits": {"gpu.intel.com/xe": "1"}
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

Check GPU clocks UNDER decode load (the throttle hypothesis) — if freq sits
well below the ~2.4 GHz boost while decoding, the host is clock/power-limiting:

```bash
# xpu-smi stats -d 0 reports freq, power, util, temp in real-time
# cat /sys/class/drm/card*/gt/gt0/rps_*_freq_mhz from a debug pod (see above)
oc -n llm exec "$POD" -- xpu-smi stats -d 0
```

Interpretation:

- **Uncontended decode ~50–76 t/s** → the gap was slot contention; done.
- **Still ~30–40 t/s AND clocks are high, no CPU spill** → likely host `xe`
  driver maturity / coopmat variant; a container-side fix won't help much.
- **Clocks low under load** → host power/thermal/governor throttling (RHCOS
  node-level), outside this app's control.

## Scaling

Scale to 0 to free the GPU when not needed. Scale up to load the model
(first start downloads ~22 GB):

```bash
oc -n llm scale deployment/llm-server --replicas=1
oc -n llm logs -f deployment/llm-server   # watch model load + Vulkan device
```

## Layout

- `base/` — namespace + shared NetworkPolicies (`deny-all`, `allow-dns-traffic`,
  `allow-openshift-monitoring`).
- `components/llama-cpp/` — llama.cpp Vulkan Deployment + init container,
  ConfigMap (router preset), PVC, service, service account, network policies
  (`allow-llm-api`, `allow-external-egress`), VPA.
- `components/open-webui/` — Open WebUI chat front-end Deployment, service,
  service account, ExternalSecret (WEBUI_SECRET_KEY + Zitadel OIDC creds),
  network policy (egress to llama.cpp :11434 + CNPG :5432).
- `components/open-webui/cnpg/` — CloudNativePG Postgres Cluster for Open WebUI
  (1 instance, 2Gi, no backup — chat data is ephemeral).
- `components/open-webui/openshift/gateway/` — HTTPRoute for
  `ai.arthurvardevanyan.com` on the shared `https-gateway`, Certificate,
  blackbox Probe. No BackendTLSPolicy (gateway terminates TLS, backend is
  plain HTTP).
- `overlays/okd/` — default; base + HuggingFace + Zitadel egress firewall.

## Open WebUI (chat front-end)

Open WebUI is deployed as a **component** alongside llama.cpp in the same
`llm` namespace and ArgoCD Application. It connects to the llama.cpp server
via the cluster-internal service (`llm-server-svc:11434`) and uses Zitadel
OIDC for SSO.

### Deployment

| Resource | Value                                                                     |
| -------- | ------------------------------------------------------------------------- |
| Image    | `ghcr.io/open-webui/open-webui:v0.11.0` (pinned digest, Renovate-managed) |
| Replicas | 1                                                                         |
| Database | CloudNativePG Postgres (`open-webui` cluster, 1 instance, 2Gi)            |
| Storage  | `/root/.local/share/open-webui` mounted from `emptyDir`                   |
| Gateway  | `ai.arthurvardevanyan.com` on `https-gateway` (TLS Terminate)             |

### OIDC / SSO

Authentication is **Zitadel OIDC** from day one. The `ExternalSecret` pulls
credentials from Vault at `secret/data/homelab/llm/open-webui/zitadel`
(`client_id`, `client_secret`). Before deploying, create an OAuth 2.0 client
in Zitadel with:

- Callback URL: `https://ai.arthurvardevanyan.com/auth/oauth/callback`
- Redirect URIs: `https://ai.arthurvardevanyan.com/auth/oauth/callback`
- Logout URL: `https://ai.arthurvardevanyan.com/auth/logout`
- Grant types: `Authorization Code`, `Refresh Token`
- Token auth method: `Client Secret Post`

> **Bootstrap:** the `ExternalSecret` targets `open-webui-config` which
> supplies `WEBUI_SECRET_KEY`, `OAUTH_CLIENT_ID`, and `OAUTH_CLIENT_SECRET`.
> The `OPENID_PROVIDER_URL` is set to `https://zitadel.arthurvardevanyan.com`
> so Open WebUI auto-discovers the OIDC endpoints.

### Database

CloudNativePG creates a `openwebui` database with `postgres` user. The
`DATABASE_URL` env var references the CNPG cluster-internal service:

```
postgresql://postgres:<password>@open-webui-rw.llm.svc.cluster.local:5432/postgres
```

> **Note:** chat history, user data, and settings are stored in Postgres.
> No CNPG backup is configured — chat data is considered ephemeral. The
> snapshot backupClassName (`csi-rbdplugin-snapclass`) is available but
> not enabled to avoid snapshot overhead for low-value data.

## REF

- <https://github.com/ggml-org/llama.cpp>
- <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF>
