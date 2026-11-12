# OpenShift Lightspeed

## Table of Contents

- [OpenShift Lightspeed](#openshift-lightspeed)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [OIDC Auth Fix](#oidc-auth-fix)
    - [The Problem](#the-problem)
    - [The Fix](#the-fix)
    - [Rollout](#rollout)
    - [Verification](#verification)
    - [Rollback](#rollback)
  - [Tool-Result Inspection Guardrail (disabled)](#tool-result-inspection-guardrail-disabled)
  - [Directory Structure](#directory-structure)
  - [Components](#components)
  - [ArgoCD](#argocd)
  - [Agentic (Tech Preview)](#agentic-tech-preview)
    - [Giving agentic runs tools (MCP)](#giving-agentic-runs-tools-mcp)
    - [Chat tools (MCP)](#chat-tools-mcp)
    - [Agent Sandbox (evaluated, not used)](#agent-sandbox-evaluated-not-used)
    - [Alert-triggered runs](#alert-triggered-runs)
  - [Known Issues](#known-issues)
    - [1. Missing `lightspeed-agent` RBAC (fixed)](#1-missing-lightspeed-agent-rbac-fixed)
    - [2. Sandbox pods cannot reach LiteLLM (fixed)](#2-sandbox-pods-cannot-reach-litellm-fixed)
    - [3. MCP session 404 with multiple replicas (fixed, inferred)](#3-mcp-session-404-with-multiple-replicas-fixed-inferred)
    - [4. Chat has no tools by default (workaround)](#4-chat-has-no-tools-by-default-workaround)
    - [5. Model never calls tools (vLLM bugs, workaround)](#5-model-never-calls-tools-vllm-bugs-workaround)
    - [6. `result CR missing options` (open)](#6-result-cr-missing-options-open)
    - [7. `tokenUsage` always 0 (open)](#7-tokenusage-always-0-open)
    - [8. Sandbox pod and logs deleted immediately (open)](#8-sandbox-pod-and-logs-deleted-immediately-open)
    - [9. Console "Loading logs..." never finishes (open, upstream)](#9-console-loading-logs-never-finishes-open-upstream)
    - [10. `disable_auth` patch lost on reconcile (fixed)](#10-disable_auth-patch-lost-on-reconcile-fixed)
    - [11. MCP tools filtered (open, not analyzed)](#11-mcp-tools-filtered-open-not-analyzed)
    - [12. Chat tool result fails the safety inspection (workaround)](#12-chat-tool-result-fails-the-safety-inspection-workaround)
  - [Troubleshooting](#troubleshooting)
    - [Console shows "Loading logs..." forever for an AgenticRun](#console-shows-loading-logs-forever-for-an-agenticrun)
    - [`ValueError: Invalid user ID`](#valueerror-invalid-user-id)
    - [Operator reverting ConfigMap changes](#operator-reverting-configmap-changes)
    - [No User/Identity objects created](#no-useridentity-objects-created)
    - ["A tool result failed the safety inspection"](#a-tool-result-failed-the-safety-inspection)

## Overview

OpenShift Lightspeed (OLS) is an AI assistant deployed on OKD 5.x. It provides a chat UI and, as a tech preview, agentic runs that investigate the cluster and propose fixes. Both use LLMs served through LiteLLM (currently qwen3.6-35b-a3b on vLLM).

## OIDC Auth Fix

### The Problem

OKD 5.x uses `type: OIDC` (not `type: OpenID`) and does not create OpenShift User/Identity objects: the upstream OIDC `sub` claim flows straight through to the TokenReview `user.uid`. ZITADEL issues snowflake user IDs (e.g. `305070630980550817`), and the OLS app server validates the authenticated user with `uuid.UUID(user.uid)`, so every chat query failed with:

```bash
ValueError: Invalid user ID 305070630980550817
```

This cannot be fixed inside the OLS config:

- The lightspeed-operator v2.0.0 CRD has no field that passes an `authentication_config` through to the app server, and the operator regenerates the `olsconfig` ConfigMap on every reconcile.
- The earlier workaround of hand-patching the ConfigMap (`authentication_config.module: noop-with-token` + `dev_config.disable_auth: true`) was itself broken: that module returns an empty user UUID and `NO_USER_TOKEN`, so MCP servers logged `MCP server openshift requires kubernetes token but none available` and chat lost cluster access. The operator also kept reverting the patch (issue 10).

### The Fix

Run a lightspeed-service build whose user-ID validation accepts opaque
IDs: [openshift/lightspeed-service#3186](https://github.com/openshift/lightspeed-service/pull/3186)
relaxes `ols/utils/suid.py:check_user_id` to a bounded opaque string
(`user_id` was already `text` in Postgres), so `ValueError: Invalid user
ID` is gone without touching cluster authentication. OLS keeps the real
`k8s` auth module with real TokenReviews: user tokens are validated as
usual and passed through to MCP servers, so chat keeps cluster access.

Until the fix ships on `registry.redhat.io`, the custom build is forced
through a **MutatingAdmissionPolicy**
([`map-ols-service-image.yaml`](overlays/okd/map-ols-service-image.yaml)).
Patching the operator Deployment's `--*-image` args proved GitOps-hostile:
the OLM operator continuously reconciles its own Deployment back to the
CSV spec, so any arg-level patch is reverted within seconds. Patching the
app-server Deployment directly (with `images:` transformer) also loops:
the operator sees the template spec differ from its desired image, bumps
`force-reload`, rewrites the Deployment, and the loop continues. The
admission policy intercepts each **Pod CREATE** (only when the stock
`registry.redhat.io` image is present) and rewrites the
`lightspeed-service-api` container image to the fixed build. The operator
creates the ReplicaSet and Deployment with the stock image — a happy path
with no conflict loop. The policy matches by label (`app.kubernetes.io/name:
lightspeed-service-api`) on the Pod spec, so only the app-server pod is
mutated; other pods and containers are untouched. Do not hand-patch the
app-server Deployment or Pods; the policy owns the override.

**History (retired 2026-11-11):** before the upstream fix merged, this
repo carried a stopgap that mapped `user.uid` to the zero-padded 32-char
hex form of `sub` in
[okd/okd-configuration/base/authentication.yaml](../okd-configuration/base/authentication.yaml)
(decimal digits are a subset of hex, so `uuid.UUID()` parsed it), plus a
`claimValidationRules` guard rejecting non-decimal `sub`s. It was a
pure workaround for the strict `uuid.UUID(user.uid)` check; with the
relaxed validation deployed the mapping is removed and `user.uid` is the
raw `sub` again. Re-add the mapping (git history) if you ever need to
run a stock `registry.redhat.io` lightspeed-service build again.

### Rollout

ArgoCD applies the MutatingAdmissionPolicy from the `openshift-lightspeed`
app (`okd/openshift-lightspeed/overlays/okd`). Removing the retired uid
claim mapping from the Authentication CR (`okd/okd-configuration` app)
rolls the kube-apiservers one at a time (brief; existing console/CLI
sessions stay logged in, and the `admin` context in `~/.kube/okd` uses a
client certificate and is unaffected). After the sync:

1. Wait for the kube-apiserver rollout to finish:
   `kubectl get co kube-apiserver` reaches `PROGRESSING=False`.
2. Confirm the app server Deployment shows the **stock** image (the
   operator creates it with the stock digest):

   ```bash
   kubectl -n openshift-lightspeed get deploy lightspeed-app-server \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

3. Confirm the **pod** shows the fixed image (admission policy rewrites
   pods on CREATE):

   ```bash
   kubectl -n openshift-lightspeed get pod -l app.kubernetes.io/name=lightspeed-service-api \
     -o jsonpath='{.items[0].spec.containers[0].image}'
   ```

4. Confirm the policy is active and matching:

   ```bash
   kubectl get mutatingadmissionpolicy map-ols-service-image -o wide
   kubectl get mutatingadmissionpolicybinding map-ols-service-image-binding -o wide
   ```

**Expected:** `kubectl get deploy ...` shows `registry.redhat.io/...` and
`kubectl get pod ...` shows `registry.arthurvardevanyan.com/homelab/...`.
This is the expected behavior — the policy only rewrites pods at creation,
so the Deployment never diverges from the operator's desired state.

### Verification

- `kubectl auth whoami -o yaml` shows the raw ZITADEL `sub` as the uid
  for OIDC users (no padding).
- App server logs show `Authentication retrieval for module k8s` (not `noop-with-token`).
- A chat query that hits MCP tools succeeds: no `ValueError: Invalid user ID` and no `MCP server openshift requires kubernetes token but none available` log lines.
- New conversation rows in the OLS database carry the raw `sub` in the `user_id` column (the column is `text`).

### Rollback

Remove the `map-ols-service-image*.yaml` files and their overlay entry
from `kustomization.yaml` and sync: the admission policy is removed,
so pods are no longer rewritten and revert to the stock image the
operator creates them with. If the stock image is still the strict-UUID
build, re-add the retired uid claim mapping to `okd/okd-configuration`
as well (see [The Fix](#the-fix) history), or chat fails again with
`ValueError: Invalid user ID`.

## Tool-Result Inspection Guardrail (disabled)

**The problem.** Once the token flow works (see [OIDC Auth Fix](#oidc-auth-fix)), chat MCP tools run and return cluster data. OLS then runs a tool-result inspection guardrail: an LLM classifier that screens each tool result for prompt injection before the model sees it. The classifier calls the **plain** `qwen3.6-35b-a3b` model with `response_format: json_schema` and no tools. The LiteLLM `strip_agentic_params` hook (see [issue 5](#5-model-never-calls-tools-vllm-bugs-workaround)) only strips `response_format` for the `-agentic` alias, so the request reaches vLLM unchanged. vLLM does not handle this structured output request correctly for this model, so the classifier fails all three retries (`outcome=classifier_error` in the `tool_result.inspection` span) and OLS aborts the turn with:

> Lightspeed stopped the operation because a tool result failed the safety inspection.

The guardrail itself is working as designed. The failure comes from the homelab vLLM backend, the same limitation as issue 5 showing up in a second, non-agentic consumer.

**The fix.** Set `spec.ols.guardrails.toolResultInspection.enabled: false` in the OLSConfig CR (`base/olsconfig.yaml`). The v2.0.0 operator renders this field into the generated ConfigMap as `ols_config.guardrails.tool_result_inspection.enabled`, so the disable is GitOps-managed and survives reconciles. This is the only flag that controls the classifier (it is built in `docs_summarizer.py` and only when the flag is `true`). Earlier this repo disabled it by hand-patching the operator-managed ConfigMap, which the operator kept reverting; do not do that again, keep the setting in the CR.

Verify: after sending one chat query, the app server logs `Tool-result inspection enabled=False` (the line is only logged per query) and never logs `Tool-result classifier initialized`:

```bash
kubectl logs -l app.kubernetes.io/name=lightspeed-service-api -n openshift-lightspeed --tail=200 | grep "Tool-result"
```

**Security tradeoff.** With the guardrail off, tool results (pod names, labels, annotations, command output) are not screened for prompt injection before reaching the model. The cluster content here is our own, so the residual risk is low. The durable fix is to make the vLLM backend honor `response_format: json_schema` for this model (or point the classifier at a model that does), then set the flag back to `true`.

## Directory Structure

```txt
okd/openshift-lightspeed/
├── base/
│   ├── alerts-adapter-config.yaml    # Alerts adapter config ConfigMap
│   ├── external-secret-llm.yaml      # External secret for LLM credentials
│   ├── installplan-approver.yaml     # OLM install plan approver
│   ├── kustomization.yaml            # Base kustomization
│   ├── namespace.yaml                # Namespace definition
│   ├── olsconfig.yaml                # OLSConfig CR (main app config)
│   ├── operatorgroup.yaml            # OperatorGroup for OLS operator
│   ├── subscription.yaml             # OLM Subscription
│   └── vpa/                          # VerticalPodAutoscaler configs
├── components/
│   └── agentic/                      # LLMProvider, Agent, ApprovalPolicy, RBAC
├── overlays/
│   └── okd/
│       ├── kustomization.yaml                        # OKD overlay
│       ├── map-ols-service-image.yaml                # MAP: override service image on pods
│       └── map-ols-service-image-binding.yaml        # MAP binding: activate for openshift-lights ns
└── README.md                         # This file
```

## Components

The tree above says what each file is. Notes that are not obvious from the names:

- **olsconfig.yaml**: controls the OLS app, LLM provider, MCP servers, guardrails and deployment resources. The operator renders it into the `olsconfig` ConfigMap; never hand-edit that ConfigMap, the operator reverts it. Everything configurable lives in this CR (and what the CRD cannot express lives in cluster config, see [OIDC Auth Fix](#oidc-auth-fix)).
- **map-ols-service-image.yaml + map-ols-service-image-binding.yaml** (in `overlays/okd/`): MutatingAdmissionPolicy that rewrites the `lightspeed-service-api` container image to the user-ID-fix build (see [OIDC Auth Fix](#oidc-auth-fix)) on Pod CREATE. The operator creates the Deployment with the stock image (happy path, no OLM churn), and the MAP rewrites the pod image on creation. Only fires when the pod has label `app.kubernetes.io/name: lightspeed-service-api` AND the image starts with the stock `registry.redhat.io` prefix — so it's a no-op if the image is already the fixed build or another image entirely. Remove once the stock image contains the upstream fix.
- **operatorgroup.yaml + subscription.yaml**: install the lightspeed operator (v2.0.0). `installplan-approver.yaml` approves its OLM install plans.
- **agenticrun-alert-tools.yaml** (in `components/agentic/`): MutatingAdmissionPolicy that injects MCP servers into alert-triggered AgenticRuns (see [Alert-triggered runs](#alert-triggered-runs)).

## ArgoCD

Deployed by the `openshift-lightspeed` ArgoCD Application, registered in `kubernetes/argocd/components/applications/okd/openshift-lightspeed.yaml`. The `agentic.openshift.io` kinds this app declares (`Agent`, `ApprovalPolicy`, `LLMProvider`) must be listed in `spec.resourceInclusions` of `kubernetes/argocd/components/argocd/argocd.yaml`, otherwise ArgoCD will not manage them. Add any new CRD kind the app starts declaring there too.

## Agentic (Tech Preview)

Agentic runs are provided by the `lightspeed-agentic-operator` (v2.0.0) and configured by the `components/agentic` Kustomize component:

- `LLMProvider` `litellm` points at `http://litellm-svc.llm.svc:4000` (model `qwen3.6-35b-a3b-agentic`, a LiteLLM alias of `qwen3.6-35b-a3b`; see [issue 5](#5-model-never-calls-tools-vllm-bugs-workaround)).
- `Agent` `default` and `ApprovalPolicy` `cluster` (Analysis: Auto, Execution: Manual, Verification: Auto).
- `ServiceAccount` `lightspeed-agent` bound to the built-in `cluster-reader` ClusterRole via `cluster-reader-binding`. Without it, the sandbox claim is rejected.
- Each stage runs in an ephemeral, label-less sandbox pod (`ls-analysis-<uid>`). The `llm` namespace NetworkPolicy (`kubernetes/llm/base/network-policy.yaml`) has a rule allowing any pod from `openshift-lightspeed` to reach LiteLLM on port 4000, because these pods cannot be selected by label.

### Giving agentic runs tools (MCP)

`Agent` has no tools field. Tools are set per run in `AgenticRun.spec.tools` and are immutable after creation. The `mcpServers` entry in `OLSConfig` only serves the classic OLS chat. Without `spec.tools`, the agent has no cluster access, so it cannot inspect anything. The console's run form does not set tools.

Working example (verified to connect; see issues 5 and 11 for what the agent then does with the tools):

```yaml
apiVersion: agentic.openshift.io/v1alpha1
kind: AgenticRun
metadata:
  generateName: ag-
  namespace: openshift-lightspeed
spec:
  analysis:
    agent: default
  request: <your request>
  tools:
    mcpServers:
      - name: openshift
        url: https://openshift-mcp-server.openshift-lightspeed.svc:8443/mcp
        timeoutSeconds: 60
        headers:
          - name: Authorization
            valueFrom:
              type: ServiceAccountToken
```

### Chat tools (MCP)

The console plugin proxies your token to the app server via `authorization: UserToken`. The app server validates it with the `k8s` auth module (real TokenReview, working again thanks to the [OIDC Auth Fix](#oidc-auth-fix)) and passes it through to MCP servers, which gives chat queries cluster access as your identity.

Verify it's working:

1. Open the Lightspeed console plugin
2. Ask: _"list pods in openshift-lightspeed"_
3. The AI should now be able to see and list the pods using MCP tools

If the chat loses tools, check the app server logs for `MCP server openshift requires kubernetes token but none available`. That means the app server is not receiving the user token (for example if someone re-enabled `disable_auth`).

### Agent Sandbox (evaluated, not used)

The Red Hat build of Agent Sandbox (`agent-sandbox-operator`, channel `preview-0.9`) was installed and removed again. It provides the `Sandbox`, `SandboxClaim`, `SandboxTemplate` and `SandboxWarmPool` CRDs, and the agentic operator can use them instead of bare pods via `OLSConfig.spec.agenticOLS.sandboxMode: sandbox-claim` (default `bare-pod`).

- It is aimed at isolating untrusted agent code (gVisor or Kata `RuntimeClass`, warm pools, persistent sandboxes). This cluster only has the `selinux` `RuntimeClass`, and the agent is read-only (`cluster-reader`), so there is nothing to gain.
- It changes neither pod lifetime nor tool calling. The operator still creates and deletes a `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim` per run, and the pod is gone about 6 seconds later (see [issue 8](#8-sandbox-pod-and-logs-deleted-immediately-open)). The model still fabricated results without calling MCP tools.
- It needs an extra Role. The OLM-generated ClusterRole for the agentic operator grants `sandboxclaims` and `sandboxtemplates` but not `sandboxwarmpools`, so a run fails with `claim sandbox: create SandboxWarmPool for analysis: ... cannot create resource "sandboxwarmpools"`. If you retry it, bind a Role in `openshift-lightspeed` granting `create, delete, get, list, patch, update, watch` on `extensions.agents.x-k8s.io/sandboxwarmpools` to the `lightspeed-agentic-operator-controller-manager` ServiceAccount.
- The agentic operator detects the CRDs only at startup (`Sandbox CRDs detected, sandbox-claim mode available`), so restart it after installing or removing them.

### Alert-triggered runs

The `lightspeed-agentic-alerts-adapter` polls AlertManager every 30s and creates `AgenticRun` CRs when alerts fire. It is configured through three pieces:

- **AlertManager route** in `okd/openshift-monitoring/overlays/okd/alertmanager.yaml`. Critical and warning alerts (excluding `Watchdog` and `InfoInhibitor`) are routed to a dedicated `lightspeed` receiver. The `continue: true` flag ensures they still reach Discord too.
- **Adapter config** in `base/alerts-adapter-config.yaml`. The `filtering.allowedReceivers` list gates which alerts produce runs. Set to `[lightspeed]`. The `agent.default` and `tools.skills` settings apply to every run. The alert route excludes `Watchdog`, `InfoInhibitor`, `ArgoCDSyncAlert` and `InstallPlanStepAppliedWithWarnings`; the latter fires during operator upgrades and is almost always noise.
- **agenticrun-alert-tools.yaml** (in `components/agentic/`): MutatingAdmissionPolicy that matches AgenticRuns created by the adapter (label `agentic.openshift.io/source=alertmanager`) and merges `spec.tools.mcpServers` with the existing skills. Without it, alert runs would get skills only and the agent would have no cluster access — the same symptom as issue 4.

Approval policy stays the same: Analysis and Verification are automatic, Execution is manual. Only investigations start without your sign-off.

To verify, after syncing:

```bash
# Check adapter is processing alerts (not skipping them all)
kubectl logs -l app.kubernetes.io/name=lightspeed-agentic-alerts-adapter -n openshift-lightspeed --tail=20 | grep 'poll cycle'

# Check alert-triggered runs exist
kubectl get agenticruns -l agentic.openshift.io/source=alertmanager -n openshift-lightspeed
```

## Known Issues

Findings from bringing up agentic runs on OKD 5.0 (tech preview). Each entry says whether it was verified or is an inference.

| #   | Issue                                               | Status             | Where it is fixed                                                                                                    |
| --- | --------------------------------------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------- |
| 1   | Sandbox claim rejected: no `lightspeed-agent` RBAC  | Fixed              | `components/agentic/{serviceaccount,rbac}.yaml`                                                                      |
| 2   | Sandbox pods cannot reach LiteLLM                   | Fixed              | `kubernetes/llm/base/network-policy.yaml`                                                                            |
| 3   | MCP session 404 with 2 MCP replicas                 | Fixed (inferred)   | `base/olsconfig.yaml` (`mcpServer.replicas: 1`)                                                                      |
| 4   | Chat has no tools unless `spec.tools` is set        | Workaround         | See [Chat tools](#chat-tools-mcp)                                                                                    |
| 5   | Model never calls tools (vLLM bugs)                 | Workaround         | `kubernetes/llm/components/litellm/strip_agentic_params.py`                                                          |
| 6   | Run fails: `result CR missing options`              | Open               | None                                                                                                                 |
| 7   | `tokenUsage` always 0                               | Open               | None                                                                                                                 |
| 8   | Sandbox pod and logs deleted immediately            | Open               | None                                                                                                                 |
| 9   | Console "Loading logs..." never finishes            | Open (upstream)    | None                                                                                                                 |
| 10  | `disable_auth` patch lost on OLS operator reconcile | Fixed              | MAP image override on Pods + `okd/okd-configuration` uid claim mapping removal (see [OIDC Auth Fix](#oidc-auth-fix)) |
| 11  | MCP tools `helm_install` and `pods_run` filtered    | Open, not analyzed | None                                                                                                                 |
| 12  | Chat tool result fails the safety inspection        | Workaround         | `base/olsconfig.yaml` (`guardrails.toolResultInspection.enabled: false`)                                             |

### 1. Missing `lightspeed-agent` RBAC (fixed)

The sandbox claim failed with `no ClusterRoleBinding found with subject openshift-lightspeed/lightspeed-agent — ensure reader RBAC is configured`. The component now creates the `lightspeed-agent` ServiceAccount and binds it to the built-in `cluster-reader` ClusterRole.

### 2. Sandbox pods cannot reach LiteLLM (fixed)

Sandbox pods (`ls-analysis-<uid>`) carry no labels, so they cannot be matched by a podSelector. The first run failed with `Request timed out`. The `llm` namespace NetworkPolicy now allows any pod from the `openshift-lightspeed` namespace to reach port 4000.

### 3. MCP session 404 with multiple replicas (fixed, inferred)

With 2 `openshift-mcp-server` replicas and `sessionAffinity: None` on the operator-managed Service, the sandbox logged `MCP server admission failed` after the MCP server answered `404 Not Found` to the follow-up requests of a session. Only one pod logged the session. After reducing to 1 replica, the same request produced clean sessions (`200`, `202`, `204`). The replica count is the only thing that changed, but the pod-affinity explanation was not confirmed directly.

The Service belongs to the operator, so affinity cannot be set from this repo. Keep `deployment.mcpServer.replicas: 1` in `base/olsconfig.yaml`. The classic OLS chat uses the same MCP server and may also have been affected by this.

### 4. Chat has no tools by default (workaround)

See [Giving chat tools](#chat-tools-mcp). Symptom: the model answers "No available MCP tools or `oc`/`kubectl` commands were provided", and `AgenticRun.spec.tools` is empty (`kubectl get agenticruns -o custom-columns=NAME:.metadata.name,TOOLS:.spec.tools`).

### 5. Model never calls tools (vLLM bugs, workaround)

Symptom: runs have a working MCP connection but the MCP server logs no tool calls, and the model answers confidently with fabricated results (for example InstallPlans in namespaces that do not exist) or "No cluster inspection needed". Always cross-check results against the cluster.

Root cause, verified by capturing the sandbox request in LiteLLM and replaying it against `qwen3.6-35b-a3b` and `qwen3.8-27b` (vLLM `0.32.0+xpu`, `--enable-auto-tool-choice --tool-call-parser qwen3_coder`). Every turn carries 34 tools, no `tool_choice`, and `response_format` of type `json_schema` (`final_output`):

1. **`response_format` suppresses tool calls.** vLLM constrains decoding to the schema from the first token, so the model cannot emit a tool call and writes the final JSON immediately. Upstream: [vllm#39929](https://github.com/vllm-project/vllm/issues/39929). vLLM can compose tools with a schema, but only through xgrammar. The `final_output` schema is rejected by xgrammar (`pattern` combined with `maxLength` on `rbac.namespaceScoped[].namespace`), so vLLM keeps the schema and drops the tools.
2. **`strict: true` tools return HTTP 500.** The sandbox's built-in tools (`read_file`, `write_file`, `list_directory`, `apply_patch`) are sent with `strict: true`. Without `response_format`, vLLM builds a structural tag that the guidance backend rejects: `KeyError: 'triggers'` in `backend_guidance.py` (`serialize_guidance_grammar`). Upstream: [vllm#55152](https://github.com/vllm-project/vllm/issues/55152).

Replay results (same captured request, LiteLLM cache disabled):

| `response_format` | `tools[].function.strict` | Result              |
| ----------------- | ------------------------- | ------------------- |
| kept              | kept                      | No tool calls       |
| kept              | removed                   | No tool calls       |
| removed           | kept                      | HTTP 500            |
| removed           | removed                   | Tool calls (5 of 5) |

No vLLM flag fixes this (forcing the xgrammar backend would reject the schema outright), and this is not a model problem.

Workaround: the `qwen3.6-35b-a3b-agentic` model alias in LiteLLM (same backend as `qwen3.6-35b-a3b`) and the hook `kubernetes/llm/components/litellm/strip_agentic_params.py`. `Agent.spec.model` points at the alias. The hook only acts on model names ending in `-agentic` whose request carries tools. Other models and clients are untouched.

1. **Pre-call:** drops `response_format` and `tools[].function.strict`, so the model can call tools. It also truncates each tool result to 20,000 characters with a note telling the model to narrow its query. The sandbox does not limit tool output: one `execute_instant_query` returned about 1.8 MB and overflowed the 262,144-token context (`ContextWindowExceededError`, 4 of 4 runs).
2. **Post-call:** buffers the streamed turn. A turn with tool calls is passed through unchanged. A turn without tool calls is the final answer: the hook makes a second, non-streamed call with the original schema and no tools, asking the model to convert its answer, and replays the stream with the JSON in place of the answer text. If that call fails, the original answer is returned.
3. **Context budget:** the sandbox resends the whole history every turn. vLLM serves 262,144 tokens, but measured runs (288 calls, 9 runs) peaked at 31K-148K with a median call of 32K and a fixed floor of about 17K (prompt plus 34 tool definitions). When the estimate (characters / 4) passes 75K tokens, the hook replaces the oldest tool results with a short note until it is under 50K. The newest 4 tool results are always kept, and results are elided in blocks of 4 so vLLM's prefix cache is invalidated rarely. The limits are constants at the top of the hook. **Not yet observed live:** no test run has reached 75K since this was added, so it is only unit-tested.
4. **CRD alignment:** for the conversion call only, the hook patches the sandbox schema so it matches the `AnalysisResult` CRD. The sandbox schema is looser and each gap failed a run with `422 Unprocessable Entity`:

- `remediationPlan.actions` `minItems: 1` (the sandbox allows empty, but the CRD requires at least one action). Fixed `remediationPlan.actions: Required value`.
- `remediationPlan.risk` enum (`Low`/`Medium`/`High`/`Critical`) and `diagnosis.confidence` enum (`Low`/`Medium`/`High`), which the sandbox schema omits entirely. Without them the model invented values like `"Low-Medium"`. Fixed `risk: Unsupported value: "Low-Medium"`.
- `additionalProperties: false` on `remediationPlan` and `diagnosis` so the model cannot produce fields the CRD rejects.
- `maxItems: 10` on `options` and `maxItems: 50` on actions, to keep the CRD happy.
  The sandbox's own schema is untouched; the patch only applies to the conversion call's schema copy.
- `options[].rbac` must have at least one property (the CRD says to omit it for advisory-only options), but the model returns `rbac: {}`, `clusterScoped: []`, or invents keys such as `clusterRoles`, `policyRules` and `policies`. The API server prunes the unknown keys and then rejects the empty object with `422 ... rbac should have at least 1 properties`. Rules missing `apiGroups` (`status.options[0].rbac.clusterScoped[1].apiGroups: Required value`) fail the same way. The hook pins `rbac` to `namespaceScoped` and `clusterScoped` with `additionalProperties: false` in the conversion schema, then drops unknown keys, rules without all of `apiGroups`/`resources`/`verbs`/`justification`, and empty `rbac` objects. The core API group `[""]` is kept. A run that previously failed with this 422 now succeeds.

What did not work, for the record:

- Moving the schema into the system prompt and appending a "reply with only JSON" reminder to the last message. The sandbox prompts ask for a natural-language final message, and 7 of 7 runs ended with a markdown report (`Invalid JSON in structured output`).
- Removing `response_format` without a replacement: tool calls work, but the run fails on the prose final answer.

Test results with the two-phase hook (request "Check if there are any operators with pending InstallPlans"):

- **minItems-only fix** (risk/confidence not yet added): 1 of 2 runs succeeded. The other failed with `risk: Unsupported value: "Low-Medium"`.
- **full CRD alignment** (risk/confidence, additionalProperties, maxItems): **5 of 5 runs succeeded**. Every run found all 7 pending InstallPlans on the cluster and proposed `oc patch installplan ... approved:true` plans.

With the context budget and `analysisSeconds: 360`, 3 of 3 sequential runs succeeded in 90-120 seconds, each finding 7/7 InstallPlans with 3 options.

Timeouts: `Agent.spec.timeouts.analysisSeconds` is 900 (it was 180, then 360, then 600). Five runs started at the same moment all failed with `AgentTimeout` ("Agent exceeded its configured execution budget") at about 3 minutes, while the same request run one at a time takes 90-120 seconds. The likely cause is the runs queueing on the single vLLM instance, but that was not measured. Alert-triggered runs need more turns than that request, so they take longer.

- **Shell tool name:** the sandbox only has the tool `exec_command` (argument `cmd`), but the skill instructions tell the model to run `bash` commands. The model calls a tool named `bash`, or puts the whole command line in the name (`bash -c "..."`, `oc get pdb -n argocd -o yaml` with stray `</parameter>` markup, or a script name like `get_events.sh`), and the run fails with `Tool bash not found in agent lightspeed`. The post-call hook rewrites those calls (streamed or not) to `exec_command` with `{"cmd": ...}`, and logs `rewrote shell tool call '...' to exec_command`. Calls that already use `exec_command` are untouched.
- **Turn steering:** alert runs investigate by calling many skill scripts and often did not conclude, so they failed with `Agent error: Max turns (N) exceeded` at 10, 20 and 30 turns. Raising `maxTurns` alone only delayed this. The pre-call hook counts earlier tool-calling turns: from 20 it appends a note asking the model to wrap up, and from 25 it removes `tools` and asks for the final analysis, so the normal JSON conversion runs. The thresholds are `NUDGE_AFTER_TURNS` and `FORCE_FINISH_AFTER_TURNS` at the top of the hook. `Agent.spec.maxTurns` is 40, so the hook acts first. The hook logs `agentic run at N tool turns` when it steps in.
- **Generation limits:** every agentic request is capped at 8192 completion tokens, and the hook sets `chat_template_kwargs.enable_thinking=false` for tool turns. **Not verified:** whether vLLM honours `enable_thinking` through LiteLLM.

Alert-triggered test (3 runs: `probefailure-argocd`, `probefailure-blackbox-exporter`, `poddisruptionbudgetlimit-argocd`), with all of the above: 3 of 3 `Succeeded`. Before turn steering the two ProbeFailure runs failed 3 times in a row with `Max turns`. One run sat in a single LLM call at turn 18 for about 14 minutes with vLLM idle (0 running, 0 waiting) and LiteLLM logging nothing, then completed. The cause was not found. The nudge was observed live (turns 15-17); the forced finish (turn 25) is unit-tested only.

Observed quality issues with `qwen3.6-35b-a3b`:

- One run misspelled an InstallPlan name (`install-j8cb7` instead of `install-j8cv7`).
- One run repeated the same 3 options 3×, producing 9 total options.
- Some runs suggested deleting InstallPlans. Execution approval is `Manual`, so review every plan before approving.

The LiteLLM key in `lightspeed-llm-credentials` has a model allowlist stored in LiteLLM's database (not in git). The alias must be added to it once, otherwise runs fail with `403 key_model_access_denied`: `POST /key/update` with the master key and `{"key": "<apitoken>", "models": ["qwen3.6-35b-a3b", "qwen3.8-27b", "qwen3.6-35b-a3b-agentic"]}`.

The console cannot add MCP tools (issue 4), so console-started runs still have no MCP tools even with this workaround.

### 6. `result CR missing options` (open)

The run status is `Failed` with reason `SandboxFailed` and message `result CR missing options` when the model returns `{"actionRequired": "True", "options": []}`. The operator rejects `actionRequired=True` with no options. It usually follows issue 4 or 5: the model cannot gather data, then marks action as required without proposing any. The sandbox step itself reports success, so the failure is only visible on the run, not in the sandbox logs.

### 7. `tokenUsage` always 0 (open)

Both `AgenticRun.status.tokenUsage` and `AnalysisResult.status.tokenUsage` are 0 on every run, including runs that clearly called the LLM. The sandbox itself logs `result: tokens=0`, so the operator and console are only passing on what the sandbox reports. A plausible cause is that the sandbox does not read usage from the LiteLLM response (for example when streaming without `stream_options.include_usage`), but this was not confirmed. Check LiteLLM's own spend logs or the `litellm_input_tokens` Prometheus metric for the real numbers.

### 8. Sandbox pod and logs deleted immediately (open)

The operator deletes the `ls-analysis-<uid>` pod the moment a step finishes (`Released bare pod`). Runs typically last 5 to 30 seconds. There is no setting to keep the pod, and `agenticOLS.sandboxMode: sandbox-claim` does not change that: per run the operator creates a `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim`, then logs `Released SandboxClaim, SandboxWarmPool, and SandboxTemplate` and deletes all of them about 6 seconds later. `terminalTTL` only controls how long the `AgenticRun` and result CRs are kept (14 days by default). The `agentic.openshift.io/templog-cleanup` finalizer suggests a temp-log mechanism, but no evidence of it working was found.

To read logs, tail the pod while it exists:

```bash
kubectl get pod -n openshift-lightspeed -w   # in one terminal
kubectl logs -f -n openshift-lightspeed ls-analysis-<uid>   # as soon as it appears
```

The agentic operator also logs the full result payload (`audit.analysis.completed`) on every run.

### 9. Console "Loading logs..." never finishes (open, upstream)

See [Troubleshooting](#console-shows-loading-logs-forever-for-an-agenticrun). A consequence of issue 8: the console plugin tries to tail a pod that no longer exists.

### 10. `disable_auth` patch lost on reconcile (fixed)

Resolved properly: the cluster runs the lightspeed-service user-ID fix (see [OIDC Auth Fix](#oidc-auth-fix)), so the OLS app server runs the stock `k8s` auth module against real TokenReviews with no `olsconfig` ConfigMap hand-patches, at the operator's normal replica count. The `noop-with-token` stopgap is retired: it also dropped the user token (`NO_USER_TOKEN`), which had broken MCP cluster access.

### 11. MCP tools filtered (open, not analyzed)

The sandbox logs `Filtered MCP tool server=openshift tool=helm_install ... reason=missing_rbac_metadata` (also `pods_run`). The full list of tools that survive the filter was not captured, so it is not known whether `resources_list` (the tool the model mentions) is available to the agent.

### 12. Chat tool result fails the safety inspection (workaround)

See [Tool-Result Inspection Guardrail](#tool-result-inspection-guardrail-disabled). Symptom: a chat query that triggers an MCP tool ends with "Lightspeed stopped the operation because a tool result failed the safety inspection." The classifier's structured output request (`response_format: json_schema`, plain `qwen3.6-35b-a3b`) fails on vLLM, so every tool result is rejected. Workaround: `spec.ols.guardrails.toolResultInspection.enabled: false` in `base/olsconfig.yaml`, which the operator renders into the ConfigMap.

## Troubleshooting

### Console shows "Loading logs..." forever for an AgenticRun

The console plugin (`lightspeed-agentic-console-rhel9`) tries to tail logs from the sandbox pod. The operator releases that pod when the stage finishes, so the request fails with `pods "ls-analysis-<uid>" not found`. This looks like an upstream console plugin bug and cannot be fixed in this repo.

The results are not lost. Read them from the CRs instead:

```bash
kubectl get analysisresults -n openshift-lightspeed
kubectl get analysisresult <name> -n openshift-lightspeed -o yaml
```

### `ValueError: Invalid user ID`

See [OIDC Auth Fix](#oidc-auth-fix). If it comes back, the admission policy is not matching — check `kubectl -n openshift-lightspeed get pod -l app.kubernetes.io/name=lightspeed-service-api -o jsonpath='{.items[0].spec.containers[0].image}'` and confirm it is running `registry.arthurvardevanyan.com/homelab/ols-userid-fix`; verify the MAP and binding are active (`kubectl get mutatingadmissionpolicy map-ols-service-image`).

### Operator reverting ConfigMap changes

The `olsconfig` ConfigMap is operator-managed: the operator rebuilds it from `base/olsconfig.yaml` on every reconciliation, so hand edits are always lost. Do not scale the operator down to keep them. Put the setting in the CR instead, and if the CRD has no field for it, the fix belongs outside OLS (that is what the [OIDC Auth Fix](#oidc-auth-fix) does).

### No User/Identity objects created

OKD 5.x `type: OIDC` does not create OpenShift User/Identity objects. The upstream OIDC `sub` flows directly through the TokenReview, which is why the UUID check fails.

### "A tool result failed the safety inspection"

See [Tool-Result Inspection Guardrail](#tool-result-inspection-guardrail-disabled). The tool-result classifier cannot run against the homelab vLLM backend, so it is disabled in the OLSConfig CR. If you re-enable it and this error returns, the backend still does not honor `response_format: json_schema` for the model.
