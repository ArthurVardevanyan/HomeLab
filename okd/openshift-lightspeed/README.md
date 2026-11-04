# OpenShift Lightspeed

## Table of Contents

- [OpenShift Lightspeed](#openshift-lightspeed)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [OIDC Auth Workaround](#oidc-auth-workaround)
  - [Directory Structure](#directory-structure)
  - [Components](#components)
  - [ArgoCD](#argocd)
  - [Agentic (Tech Preview)](#agentic-tech-preview)
    - [Alert-triggered runs](#alert-triggered-runs)
    - [Giving agentic runs tools (MCP)](#giving-agentic-runs-tools-mcp)
    - [Agent Sandbox (evaluated, not used)](#agent-sandbox-evaluated-not-used)
  - [Known Issues](#known-issues)
  - [Troubleshooting](#troubleshooting)

## Overview

OpenShift Lightspeed (OLS) is an AI assistant deployed on OKD 5.x. It provides a chat UI and, as a tech preview, agentic runs that investigate the cluster and propose fixes. Both use LLMs served through LiteLLM (currently qwen3.6-35b-a3b on vLLM).

## OIDC Auth Workaround

### The Problem

OKD 5.x uses `type: OIDC` for authentication (not `type: OpenID`). This means upstream OIDC `sub` claims (ZITADEL snowflake user IDs) are used directly as TokenReview `user.uid`. OLS hardcodes a UUID validation on `user_id` that expects a proper UUID format — but ZITADEL's OIDC `sub` is a snowflake (e.g., `305070630980550817`), not a UUID. This causes:

```bash
ValueError: Invalid user ID 305070630980550817
```

### The Fix

`dev_config.disable_auth: true` in the `olsconfig` ConfigMap disables OLS auth checks, assigning a fixed default UUID user ID instead of rejecting the snowflake.

This workaround is applied as a **hand-edit** on the operator-managed ConfigMap. The operator will overwrite it on the next reconciliation (triggered by OLSConfig CR changes or periodic resync).

### How to Apply/Reapply

```bash
# Patch the ConfigMap
kubectl patch configmap olsconfig -n openshift-lightspeed \
  --type=merge \
  -p '{"data":{"olsconfig.yaml":"dev_config:\n  disable_auth: true\n"}}'

# Restart OLS API pods to pick up the change
kubectl rollout restart deployment lightspeed-app-server -n openshift-lightspeed

# Verify
kubectl logs -l app.kubernetes.io/name=lightspeed-service-api -n openshift-lightspeed --tail=20 | grep "Auth checks disabled"
```

To undo (re-enable auth): remove the `dev_config` block from the ConfigMap and restart.

### Limitations

- All users share one identity (`00000000-0000-0000-0000-000000000000`)
- No per-user conversation isolation or history partitioning
- Auth bypass — unauthenticated requests are accepted

### Why Not a Permanent Fix

A durable fix requires patching the OLS operator or API image to handle non-UUID (OIDC) user IDs — either by deriving `user_id` from the OpenShift User object's `metadata.uid` (a real UUID) or relaxing the UUID check. This is a more involved effort (image build + operator override) and has not yet been pursued.

## Directory Structure

```txt
okd/openshift-lightspeed/
├── base/
│   ├── alerts-adapter-config.yaml    # Alerts adapter config ConfigMap
│   ├── alerts-run-tools.yaml         # Kyverno ClusterPolicy for alert tools
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
│       └── kustomization.yaml        # OKD overlay
└── README.md                         # This file
```

## Components

The tree above says what each file is. Notes that are not obvious from the names:

- **olsconfig.yaml**: controls the OLS app, LLM provider, MCP servers and deployment resources. The operator is kept at 0 replicas, so changes here need the procedure in [issue 10](#10-disable_auth-patch-lost-on-reconcile-known-manual).
- **operatorgroup.yaml + subscription.yaml**: install the lightspeed operator (v2.0.0). `installplan-approver.yaml` approves its OLM install plans.
- **alerts-run-tools.yaml**: Kyverno ClusterPolicy that injects MCP servers into alert-triggered AgenticRuns (see [Alert-triggered runs](#alert-triggered-runs)).

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

### Agent Sandbox (evaluated, not used)

The Red Hat build of Agent Sandbox (`agent-sandbox-operator`, channel `preview-0.9`) was installed and removed again. It provides the `Sandbox`, `SandboxClaim`, `SandboxTemplate` and `SandboxWarmPool` CRDs, and the agentic operator can use them instead of bare pods via `OLSConfig.spec.agenticOLS.sandboxMode: sandbox-claim` (default `bare-pod`).

- It is aimed at isolating untrusted agent code (gVisor or Kata `RuntimeClass`, warm pools, persistent sandboxes). This cluster only has the `selinux` `RuntimeClass`, and the agent is read-only (`cluster-reader`), so there is nothing to gain.
- It changes neither pod lifetime nor tool calling. The operator still creates and deletes a `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim` per run, and the pod is gone about 6 seconds later (see [issue 8](#8-sandbox-pod-and-logs-deleted-immediately-open)). The model still fabricated results without calling MCP tools.
- It needs an extra Role. The OLM-generated ClusterRole for the agentic operator grants `sandboxclaims` and `sandboxtemplates` but not `sandboxwarmpools`, so a run fails with `claim sandbox: create SandboxWarmPool for analysis: ... cannot create resource "sandboxwarmpools"`. If you retry it, bind a Role in `openshift-lightspeed` granting `create, delete, get, list, patch, update, watch` on `extensions.agents.x-k8s.io/sandboxwarmpools` to the `lightspeed-agentic-operator-controller-manager` ServiceAccount.
- The agentic operator detects the CRDs only at startup (`Sandbox CRDs detected, sandbox-claim mode available`), so restart it after installing or removing them.

### Alert-triggered runs

The `lightspeed-agentic-alerts-adapter` polls AlertManager every 30s and creates `AgenticRun` CRs when alerts fire. It is configured through three pieces:

- **AlertManager route** in `okd/openshift-monitoring/overlays/okd/alertmanager.yaml`. Critical and warning alerts (excluding `Watchdog` and `InfoInhibitor`) are routed to a dedicated `lightspeed` receiver. The `continue: true` flag ensures they still reach Discord too.
- **Adapter config** in `base/alerts-adapter-config.yaml`. The `filtering.allowedReceivers` list gates which alerts produce runs. Set to `[lightspeed]`. The `agent.default` and `tools.skills` settings apply to every run.
- **Kyverno ClusterPolicy** in `base/alerts-run-tools.yaml`. The Kyverno policy matches AgenticRuns created by the adapter (label `agentic.openshift.io/source=alertmanager`) and merges `spec.tools.mcpServers` with the existing skills. Without it, alert runs would get skills only and the agent would have no cluster access — the same symptom as issue 4.

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

| #   | Issue                                               | Status             | Where it is fixed                                               |
| --- | --------------------------------------------------- | ------------------ | --------------------------------------------------------------- |
| 1   | Sandbox claim rejected: no `lightspeed-agent` RBAC  | Fixed              | `components/agentic/{serviceaccount,rbac}.yaml`                 |
| 2   | Sandbox pods cannot reach LiteLLM                   | Fixed              | `kubernetes/llm/base/network-policy.yaml`                       |
| 3   | MCP session 404 with 2 MCP replicas                 | Fixed (inferred)   | `base/olsconfig.yaml` (`mcpServer.replicas: 1`)                 |
| 4   | Runs have no tools unless `spec.tools` is set       | Workaround         | See [Giving agentic runs tools](#giving-agentic-runs-tools-mcp) |
| 5   | Model never calls tools (vLLM bugs)                 | Workaround         | `kubernetes/llm/components/litellm/strip_agentic_params.py`     |
| 6   | Run fails: `result CR missing options`              | Open               | None                                                            |
| 7   | `tokenUsage` always 0                               | Open               | None                                                            |
| 8   | Sandbox pod and logs deleted immediately            | Open               | None                                                            |
| 9   | Console "Loading logs..." never finishes            | Open (upstream)    | None                                                            |
| 10  | `disable_auth` patch lost on OLS operator reconcile | Known, manual      | See [OIDC Auth Workaround](#oidc-auth-workaround)               |
| 11  | MCP tools `helm_install` and `pods_run` filtered    | Open, not analyzed | None                                                            |

### 1. Missing `lightspeed-agent` RBAC (fixed)

The sandbox claim failed with `no ClusterRoleBinding found with subject openshift-lightspeed/lightspeed-agent — ensure reader RBAC is configured`. The component now creates the `lightspeed-agent` ServiceAccount and binds it to the built-in `cluster-reader` ClusterRole.

### 2. Sandbox pods cannot reach LiteLLM (fixed)

Sandbox pods (`ls-analysis-<uid>`) carry no labels, so they cannot be matched by a podSelector. The first run failed with `Request timed out`. The `llm` namespace NetworkPolicy now allows any pod from the `openshift-lightspeed` namespace to reach port 4000.

### 3. MCP session 404 with multiple replicas (fixed, inferred)

With 2 `openshift-mcp-server` replicas and `sessionAffinity: None` on the operator-managed Service, the sandbox logged `MCP server admission failed` after the MCP server answered `404 Not Found` to the follow-up requests of a session. Only one pod logged the session. After reducing to 1 replica, the same request produced clean sessions (`200`, `202`, `204`). The replica count is the only thing that changed, but the pod-affinity explanation was not confirmed directly.

The Service belongs to the operator, so affinity cannot be set from this repo. Keep `deployment.mcpServer.replicas: 1` in `base/olsconfig.yaml`. The classic OLS chat uses the same MCP server and may also have been affected by this.

### 4. Runs have no tools by default (workaround)

See [Giving agentic runs tools](#giving-agentic-runs-tools-mcp). Symptom: the model answers "No available MCP tools or `oc`/`kubectl` commands were provided", and `AgenticRun.spec.tools` is empty (`kubectl get agenticruns -o custom-columns=NAME:.metadata.name,TOOLS:.spec.tools`).

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
- `options[].rbac` must have at least one property (the CRD says to omit it for advisory-only options), but the model sometimes returns `rbac: {}`, which fails with `422 ... rbac should have at least 1 properties` (seen on an alert-triggered run). The hook removes empty `rbac` objects after conversion instead of changing the schema, so the model is not pushed to invent RBAC. **Not yet observed live:** it is unit-tested only.

What did not work, for the record:

- Moving the schema into the system prompt and appending a "reply with only JSON" reminder to the last message. The sandbox prompts ask for a natural-language final message, and 7 of 7 runs ended with a markdown report (`Invalid JSON in structured output`).
- Removing `response_format` without a replacement: tool calls work, but the run fails on the prose final answer.

Test results with the two-phase hook (request "Check if there are any operators with pending InstallPlans"):

- **minItems-only fix** (risk/confidence not yet added): 1 of 2 runs succeeded. The other failed with `risk: Unsupported value: "Low-Medium"`.
- **full CRD alignment** (risk/confidence, additionalProperties, maxItems): **5 of 5 runs succeeded**. Every run found all 7 pending InstallPlans on the cluster and proposed `oc patch installplan ... approved:true` plans.

With the context budget and `analysisSeconds: 360`, 3 of 3 sequential runs succeeded in 90-120 seconds, each finding 7/7 InstallPlans with 3 options.

Timeouts: `Agent.spec.timeouts.analysisSeconds` is 360 (it was 180). Five runs started at the same moment all failed with `AgentTimeout` ("Agent exceeded its configured execution budget") at about 3 minutes, while the same request run one at a time takes 90-120 seconds. The likely cause is the runs queueing on the single vLLM instance, but that was not measured. Run them one at a time when testing.

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

### 10. `disable_auth` patch lost on reconcile (known, manual)

The OLS operator (`lightspeed-operator-controller-manager`) is kept at 0 replicas so it does not overwrite the hand-patched `olsconfig` ConfigMap. That also means changes to the `OLSConfig` CR in git (for example `mcpServer.replicas`) do not take effect until the operator is briefly scaled up.

Procedure used to apply `OLSConfig` changes:

```bash
export KUBECONFIG=$HOME/.kube/okd
N=openshift-lightspeed
# 1. Save the patched ConfigMap
kubectl get cm olsconfig -n $N -o jsonpath='{.data.olsconfig\.yaml}' > /tmp/olsconfig-before.yaml
# 2. Let the operator reconcile (wait for the Deployment change and the app-server rollout)
kubectl scale deploy lightspeed-operator-controller-manager -n $N --replicas=1
kubectl rollout status deploy/lightspeed-operator-controller-manager -n $N
kubectl rollout status deploy/lightspeed-app-server -n $N
# 3. Scale back down and restore the ConfigMap
kubectl scale deploy lightspeed-operator-controller-manager -n $N --replicas=0
python3 -c "import json; print(json.dumps({'data': {'olsconfig.yaml': open('/tmp/olsconfig-before.yaml').read()}}))" > /tmp/patch.json
kubectl patch cm olsconfig -n $N --type=merge --patch-file /tmp/patch.json
kubectl rollout restart deploy/lightspeed-app-server -n $N
```

OLM can scale the operator back up on its own. While removing the Agent Sandbox operator the Deployment returned to 1 replica twice within minutes, each time resetting the `olsconfig` ConfigMap and recreating the app-server pods. The CSV logged `InstallWaiting ... Deployment does not have minimum availability` just before. The cause is not confirmed (OLM reverting `spec.replicas` after CSV or Subscription changes is the likely one), so after any OLM activity in the cluster, check `kubectl get deploy lightspeed-operator-controller-manager -n openshift-lightspeed` and that `disable_auth` is still in the ConfigMap.

The `Auth checks disabled` log line mentioned in [How to Apply/Reapply](#how-to-applyreapply) was not seen after the last restore, even though the mounted `/etc/ols/olsconfig.yaml` contained both `dev_config` blocks. Confirm the workaround in the UI rather than relying on that log line.

### 11. MCP tools filtered (open, not analyzed)

The sandbox logs `Filtered MCP tool server=openshift tool=helm_install ... reason=missing_rbac_metadata` (also `pods_run`). The full list of tools that survive the filter was not captured, so it is not known whether `resources_list` (the tool the model mentions) is available to the agent.

## Troubleshooting

### Console shows "Loading logs..." forever for an AgenticRun

The console plugin (`lightspeed-agentic-console-rhel9`) tries to tail logs from the sandbox pod. The operator releases that pod when the stage finishes, so the request fails with `pods "ls-analysis-<uid>" not found`. This looks like an upstream console plugin bug and cannot be fixed in this repo.

The results are not lost. Read them from the CRs instead:

```bash
kubectl get analysisresults -n openshift-lightspeed
kubectl get analysisresult <name> -n openshift-lightspeed -o yaml
```

### `ValueError: Invalid user ID`

See [OIDC Auth Workaround](#oidc-auth-workaround) above.

### Operator reverting ConfigMap changes

The `olsconfig` ConfigMap is operator-managed, so the operator overwrites hand edits to `dev_config` on its next reconciliation. Keep the operator scaled to `0` (see [issue 10](#10-disable_auth-patch-lost-on-reconcile-known-manual), which also covers applying `OLSConfig` changes from git). A durable fix needs the patched image described in [Why Not a Permanent Fix](#why-not-a-permanent-fix).

### No User/Identity objects created

OKD 5.x `type: OIDC` does not create OpenShift User/Identity objects. The upstream OIDC `sub` flows directly through the TokenReview, which is why the UUID check fails.
