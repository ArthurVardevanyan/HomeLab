# Open WebUI (Chat Front-end)

Open WebUI is the chat front-end for the local LLM stack, providing a web UI
for interacting with the llama-swap backend via LiteLLM.

## Table of Contents

- [Open WebUI (Chat Front-end)](#open-webui-chat-front-end)
  - [Table of Contents](#table-of-contents)
  - [Deployment](#deployment)
    - [Deployment details](#deployment-details)
    - [Header forwarding](#header-forwarding)
  - [OIDC / SSO](#oidc--sso)
  - [Database \& WebSockets](#database--websockets)
  - [Storage](#storage)
  - [Document RAG](#document-rag)
    - [Task-model offload (deferred)](#task-model-offload-deferred)
    - [RAG vs. web search](#rag-vs-web-search)
    - [Freshness / staleness](#freshness--staleness)
    - [Knowledge Base Sync (oikb)](#knowledge-base-sync-oikb)
  - [Scaling](#scaling)
  - [References](#references)

## Deployment

Open WebUI is deployed as a separate ArgoCD application in the `llm` namespace.
It connects to llama-swap via LiteLLM (pointing to the LiteLLM service URL).

### Deployment details

The deployment (`components/open-webui/deployment.yaml`) includes:

- `open-webui-data` PVC for document storage
- Service account with minimal permissions
- Network policies restricting access
- VPA for automatic resource scaling
- Environment variables for configuration (OIDC, RAG, feature flags)

### Header forwarding

OpenWebUI strips certain headers from incoming requests when forwarding to
upstream LLM backends (LiteLLM, Ollama, etc.). Our fork patches three files to
forward two headers that were previously dropped:

| Header            | Purpose                   | Forwarded To         |
| ----------------- | ------------------------- | -------------------- |
| `X-Session-ID`    | Session/activity tracking | LiteLLM → llama-swap |
| `X-Forwarded-For` | Real client IP tracking   | LiteLLM → llama-swap |

Both are forwarded in `routers/openai.py`, `routers/ollama.py`, and
`utils/tools.py` using the same pattern as the existing `X-Session-ID` forwarding.

These patches are submitted upstream:

- **X-Session-ID**: [Discussion #28931](https://github.com/open-webui/open-webui/discussions/28931) (converted from Issue #28927)
- **X-Forwarded-For**: [Discussion #28960](https://github.com/open-webui/open-webui/discussions/28960) (Issue [#28959](https://github.com/open-webui/open-webui/issues/28959))

Without these patches, OpenWebUI acts as a header black hole for API clients
(e.g. OpenCode, curl) that rely on header propagation through proxies.
The patches follow the existing pattern of forwarding `X-Session-ID` and
`X-OpenWebUI-*` headers when `ENABLE_FORWARD_USER_INFO_HEADERS` is set.

## OIDC / SSO

Open WebUI uses the same Keycloak OIDC configuration as the rest of the cluster.
Configure the OIDC client in the Keycloak admin console and set the environment
variables in the Open WebUI deployment.

## Database & WebSockets

Open WebUI requires PostgreSQL for its database and uses WebSockets for
real-time streaming during generation. The PostgreSQL instance is deployed
via CloudNativePG (`components/cnpg-open-webui/`).

## Storage

Open WebUI stores uploaded documents, user avatars, and session data on a
PersistentVolumeClaim (`open-webui-data`, `ReadWriteMany`, `rook-cephfs`, 5Gi`— see`components/open-webui/pvc.yaml`).

## Document RAG

RAG (Retrieval-Augmented Generation) allows Open WebUI to answer questions
based on uploaded documents. Documents are embedded and stored in the vector
store, then retrieved during generation.

### Task-model offload (deferred)

Open WebUI has no `TASK_MODEL` / `TASK_MODEL_EXTERNAL` configured, so
internal helper calls — chat title generation, tag generation, retrieval
query rewriting, and follow-up suggestions — all run against the same
public chat model (typically the 35B) as the user's actual request. The
observed input:output token ratio (5.17M input / 326K output tokens) is
consistent with meaningful task-call overhead riding on top of real
generation. Pointing `TASK_MODEL` at a smaller model, or disabling individual
features (`ENABLE_TAGS_GENERATION`, `ENABLE_FOLLOW_UP_GENERATION`, etc.) via
env vars in `components/open-webui/deployment.yaml`, is a candidate follow-up
— not yet implemented.

### RAG vs. web search

RAG operates on uploaded documents only. Web search (via tools like DuckDuckGo)
is a separate capability. RAG is deterministic (based on your data); web
search is dynamic but uncontrolled.

### Freshness / staleness

Uploaded documents are re-embedded on each upload. There is no automatic
re-indexing — stale documents must be manually removed and re-uploaded.
For automated document ingestion, see [Roadmap: connector auto-sync (Onyx)](../README.md#roadmap-connector-auto-sync-onyx).

### Knowledge Base Sync (oikb)

[oikb](../../oikb/) is a background daemon that continuously syncs knowledge
bases from configured sources (GitHub repos, web sitemaps, etc.) into Open
WebUI's vector store. It runs as a standalone deployment in the `llm` namespace.

oikb is **not** connected as a Tool Server (no admin-level MCP integration).
Instead, it syncs data silently and users manually attach knowledge bases
to their chats when needed. This avoids exposing the sync endpoints to all
users.

#### Sync sources (configured in `components/oikb/oikb.yaml`)

| Source  | Format                  | Example                                             |
| ------- | ----------------------- | --------------------------------------------------- |
| Sitemap | `web:<url>`             | `web:https://www.arthurvardevanyan.com/sitemap.xml` |
| GitHub  | `github:<owner>/<repo>` | `github:ArthurVardevanyan/HomeLab`                  |

Each source has a `kb-id` pointing to an Open WebUI knowledge base UUID.

#### Attaching a knowledge base in Open WebUI (manual, per-chat)

1. Open your chat in Open WebUI.
2. Click the **paperclip** or **knowledge** icon in the message composer.
3. Select the knowledge base you want to attach (e.g. `homelab`, `personal-site`).
4. The model will now retrieve from that KB when answering your question.

The KB is attached for the duration of that chat. Start a new chat to attach
a different KB or none at all.

> **Note:** Knowledge bases are per-user in Open WebUI. When oikb syncs data
> to a KB, it syncs to the global vector store. Each user decides which KBs
> to attach to their chats.

#### Verifying oikb sync status

```bash
export KUBECONFIG=$HOME/.kube/okd
oc -n llm logs deploy/oikb --tail=20
```

Look for lines like:

```text
Sync completed for github:ArthurVardevanyan/HomeLab in 45s
```

#### Retrieving the oikb API key from Vault

The oikb API key is stored in Vault at `homelab/llm/oikb` (property: `daemon_key`). Retrieve it with:

```bash
vault kv get -field=daemon_key homelab/llm/oikb
```

Or via the Vault UI: navigate to `Secrets` → `KV v2` → `homelab` → `llm` → `oikb` → `daemon_key`.

This key is used to authenticate Open WebUI when connecting to oikb as a Tool Server (if configured manually).

## Scaling

See [Scaling](../README.md#scaling) in the main README for throughput scaling
guidance across the entire stack.

## References

- [Open WebUI](https://github.com/open-webui/open-webui)
