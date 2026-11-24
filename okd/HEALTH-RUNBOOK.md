# OKD Health Check Runbook

## Table of Contents

- [OKD Health Check Runbook](#okd-health-check-runbook)
  - [Table of Contents](#table-of-contents)
  - [When to Use](#when-to-use)
  - [Phase 1 — Collect the Must-Gather](#phase-1--collect-the-must-gather)
  - [Phase 2 — Static Analysis of the Must-Gather](#phase-2--static-analysis-of-the-must-gather)
  - [Phase 3 — Live Checks (MCP and kubectl)](#phase-3--live-checks-mcp-and-kubectl)
    - [Prometheus Tools](#prometheus-tools)
    - [Parsing Tool Output](#parsing-tool-output)
    - [Metric and Label Map (this cluster)](#metric-and-label-map-this-cluster)
  - [Phase 4 — Analysis and Reporting](#phase-4--analysis-and-reporting)
  - [Post-Remediation Follow-ups](#post-remediation-follow-ups)
  - [Pitfalls Learned](#pitfalls-learned)
  - [Verification Checklist](#verification-checklist)

## When to Use

Use this runbook for a full OKD cluster health assessment (or after an
incident): it covers collecting a must-gather, working around its known
gaps, driving the live `openshift-mcp` server without getting burned by its
tool quirks, and turning the raw data into a severity-grouped report.
Reference output of a full run: [notes/cluster-health/](../notes/cluster-health/).

Ground rules (see `AGENTS.md`):

- `export KUBECONFIG=$HOME/.kube/okd` before any `kubectl`/`oc`/`helm`.
- Read-only by default. Confirm with the user before any mutating command.
- Any pod you create ad hoc must satisfy the `restricted-v2` SCC (see
  `AGENTS.md` for the template).

## Phase 1 — Collect the Must-Gather

```bash
export KUBECONFIG=$HOME/.kube/okd
mkdir -p /tmp/must-gather
oc adm must-gather --local --output-dir=/tmp/must-gather
```

The output root is named
`must-gather.local.<cluster-id>.<UTC-timestamp>` and contains a
`quay-io-okd-scos-<sha>/` directory. Key locations:

| Path                                    | Contents                                                     |
| --------------------------------------- | ------------------------------------------------------------ |
| `cluster-scoped-resources/`             | nodes, clusteroperators, clusterversion, etcd, etc.          |
| `etcd_info/`                            | etcd endpoint status (members, db size, leader, alarms)      |
| `namespaces/<ns>/pods/<pod>/<pod>.yaml` | per-pod YAML — **partial coverage** (see gaps)               |
| `namespaces/<ns>/...`                   | services, deployments, events, configmaps, …                 |
| `nodes/`                                | node objects                                                 |
| `host_service_logs/`                    | host journald/service logs — **often stale**                 |
| `machine_config_termination_logs/`      | MCD render/reboot history                                    |
| `monitoring/`                           | prometheus config + rules (`rules.json`), alertmanager state |

**Known gaps (observed 2026-11-24 — verify after every collection):**

1. Per-pod YAMLs covered only 92 of 165 namespaces. Always cross-check pod
   state against a live `pods_list` (Phase 3).
2. `host_service_logs` ended a full day before the incident and contained
   hostnames from a previous cluster generation (`server-5`…`server-9`) —
   check the _latest timestamp_ inside them before trusting them.
3. `dmesg` files were 0 bytes — no kernel ring buffer captured.
4. Kubelet logs covered only the trailing 8 h.
5. MCD termination logs only covered the 11-20 reboot wave; later MCD
   activity left nothing behind.

**Rule of thumb:** take the MG as early as possible in the incident —
host-side evidence is the first thing to rotate out of existence.

## Phase 2 — Static Analysis of the Must-Gather

Work the MG in this order (cheap → expensive):

1. **Cluster health**: `cluster-scoped-resources/` — all
   `ClusterOperator`s converged? `ClusterVersion` history clean? etcd
   (members, db size vs limit, leader, alarms)?
2. **Node timeline**: node objects (Ready/condition _timestamps_),
   `machine_config_termination_logs/` (which node rebooted into which
   render, when), kubelet logs. Kubelet `startTime` in the live node object
   (or the kubelet summary, Phase 3) tells you whether a NotReady episode
   involved a real reboot — the single most useful discriminator.
3. **Pod scan** (mind the coverage gap from Phase 1). The per-pod YAMLs are
   multi-document files; parse with a multi-doc-aware tool, e.g.:

   ```bash
   MG=/tmp/must-gather/must-gather.local.*/quay-io-okd-scos-*
   for f in $MG/namespaces/*/pods/*/*.yaml; do
     yq e 'select(.kind == "Pod") |
       [.metadata.namespace, .metadata.name, .status.phase,
        (.status.containerStatuses // [] | map(.restartCount) | add // 0),
        (.status.containerStatuses // [] | map(select(.state.terminated.reason == "OOMKilled")) | length),
        (.status.conditions // [] | map(select(.type == "PodScheduled" and .status == "False")) | length)]
       | @tsv' "$f" 2>/dev/null
   done
   ```

   Then: count non-Running pods (expect only Succeeded Jobs), OOMKilled,
   unscheduled (PodScheduled=False), and rank by restart count (a pod with
   100+ restarts at snapshot time is chronic, not incident-related).

4. **Kubelet logs** (the incident gold mine):
   - `grep -c "Failed to update lease"` and `"Error updating node status"`
     per node — and **compare across nodes in the same time window** (zero
     on the others ⇒ node-local problem).
   - `grep -c "Eviction manager"` per node; then
     `grep "cannot evict a critical pod" | grep -o 'pod .\{0,60\}' | sort |
uniq -c | sort -rn` to see what it keeps trying to evict and against
     which pods.
   - Note the log _time window_ (MG kubelet logs are truncated to hours).
5. **Monitoring state**: `monitoring/prometheus/rules.json` (and the
   monitoring namespace configmaps) contain the _definitions_ of every alert
   (expr + `for` + severity). Whenever an alert needs interpreting, read its
   rule from here instead of guessing.
6. **Events**: node/pod events in the MG give condition transitions
   (NotReady/Ready with timestamps) — use them to bound incident windows
   before looking at logs.

## Phase 3 — Live Checks (MCP and kubectl)

The `openshift-mcp` server (`https://mcp.okd.homelab.arthurvardevanyan.com/mcp`,
Zitadel OAuth, `cluster_auth_mode = passthrough` — queries run with _your_
credentials) is the fast path for live data. Its contract is quirky; the
following quirks were each learned the hard way in the 2026-11-24 run:

### Prometheus Tools

- `list_metrics` requires a non-trivial `name_regex` (bare `.*` is
  rejected). Always verify a metric name exists before querying — the
  backend also rejects unknown metric names with a clear error
  (e.g. `node_filesystem_capacity_bytes` does not exist here; the real
  names are `node_filesystem_{size,avail,free}_bytes`).
- `execute_instant_query` requires a **label matcher on every metric** —
  bare `ALERTS` is rejected. Use e.g. `ALERTS{alertname=~"A|B"}`.
- `execute_range_query` needs `start` + `end` **together** (or
  `duration` + `end`) plus a `step`. It returns a **pre-aggregated
  summary** — `{resultType:"matrix", summary:[{series:{...}, min, max,
avg, count, firstTimestamp}]}` — _no raw points and no per-point
  timestamps_. To localize _when_ in a window something happened, **bisect
  the window** (e.g. 15-min ranges at 30 s/1 m step) and compare min/max
  across the halves.

### Parsing Tool Output

- Most tools return either kubectl-style tables or JSON _strings_ — parse
  both defensively (try `JSON.parse`, fall back to table parsing; split
  table rows on 2+ spaces).
- `nodes_stats_summary {name}`: `node.fs` is a **single object**
  (`{time, availableBytes, capacityBytes, usedBytes, inodes...}`), _not_
  an array; `node.memory.psi` / `node.cpu.psi` are objects
  (`{full:{total,avg10,avg60,avg300}, some:{...}}`). Guard every method
  call (`Array.isArray` first) — calling `.filter` etc. on a non-array
  throws "The called value is not a function" in the Code Mode runtime.
- `pods_list` **ignores its `namespace` argument** (always all namespaces)
  and returns a 14-column table (NAMESPACE, APIVERSION, KIND, NAME, READY,
  STATUS, RESTARTS, AGE, IP, NODE, …). Use `pods_list_in_namespace` to
  scope.
- `resources_list` needs a **fully versioned** `apiVersion`
  (`argoproj.io/v1alpha1` works; bare `argoproj.io` gives "no matches for
  kind").
- `helm_list {all_namespaces: true}` — note this cluster has exactly one
  Helm release (istiod); everything else is GitOps.
- `probe_http` can return `400` with _empty headers_ when hitting Go TLS
  listeners — that is a **probe artifact** (malformed/plain request), not a
  real HTTP 400. Always run a control probe (e.g. router `:80`) before
  trusting probe status codes; use TLS errors (SAN/CA) as the real signal.
- `get_service_endpoints {namespace, service}`: the "KeyFields" section is
  the EndpointSlice — its ports are **target (pod) ports**, not the
  client-facing Service ports. Check the Service for what clients dial.

### Metric and Label Map (this cluster)

- `instance` / `node` labels are **node names** (`server-1`, …), not IPs.
- Memory: `node_memory_MemAvailable_bytes{instance=...}`.
- PSI: **not in Prometheus** — get it from the kubelet Summary API via
  `nodes_stats_summary` (psi `avg10/60/300` are the live pressure signals;
  `total` is cumulative since boot — don't read it as "per 24 h").
- Filesystems: `node_filesystem_{size,avail,free}_bytes` with
  `mountpoint` (imagefs = `mountpoint="/var/lib/containers"`);
  `node_filesystem_capacity_bytes` does not exist. `gpu-1` reports no
  series for that mountpoint.
- Descheduler: `descheduler:node:eviction_count:10m{node=...}`
  (colon-prefixed recording-rule naming — there are 46 such metrics),
  counters `descheduler_pods_evicted[_total]` (one series _per pod_).
- `node_collector_evictions_total` exists in the registry but has **no
  samples** — don't rely on it for kubelet evictions; use kubelet logs or
  PSI.
- Active alerts: `ALERTS{alertname=~"..."}` (value `1` = firing; includes
  the always-on synthetic `Watchdog`).
- API server: `sum(rate(apiserver_request_total{code=~"5.."}[1m]))`.

**Fixed in PR #866:** `get_alerts` / `get_silences` failed because
`alertmanager_url` pointed at pod port 9095 (the TLS sidecar) instead of
the Service web port 9094 — the one-line fix in
`okd/mcp-server/base/config.toml` is PR #866. Until it merges, use the
`ALERTS{...}` metric above as the alerts source.

**kubectl ground truth (read-only)** — use when MCP data needs a second
opinion, e.g. PDB status (the MCP has no PDB tool):

```bash
kubectl get pdb -A -o json | jq -r '.items[] |
  [.metadata.namespace, .metadata.name,
   (.spec.minAvailable // "-"),
   .status.currentHealthy, .status.desiredHealthy,
   .status.disruptionsAllowed,
   ((.status.conditions // []) | map(.type + "=" + .status) | join(" ")),
   .status.conditions[0].lastTransitionTime] | @tsv'
```

Then resolve each PDB's selector and list the matching pods with nodes:

```bash
kubectl get pods -n <ns> -l "cnpg.io/cluster=<x>,cnpg.io/instanceRole=primary" -o wide
```

CNPG cluster state (phase, archiver/backup config):

```bash
kubectl get clusters.postgresql.cnpg.io -A
kubectl get clusters.postgresql.cnpg.io <name> -n <ns> -o jsonpath='{.status.phase} {.spec.backup}'
```

**Blip forensics recipe** (for a NotReady event at time T on node N):

1. MG kubelet logs around T: first/last lease failure, target host.
2. Node condition transitions (MG events / live node object).
3. kubelet `startTime` (reboot, or just an API-side blip?).
4. Range queries at 1 m step over `[T-12m, T+10m]`:
   - `node_memory_MemAvailable_bytes{instance=N}` (memory dip?)
   - `sum(rate(apiserver_request_total{code=~"5.."}[1m]))` (bisect to place
     any 5xx peak: _before_ T ⇒ apiserver-side; _at_ T ⇒ likely reaction
     to the node dropping).
5. Lease failures on the _other_ nodes in the same window (node-local vs
   cluster-wide; same-minute flaps on multiple nodes ⇒ shared infra).
6. Exposure: what was on node N at T (`kubectl get pods -o wide`)? CNPG
   primaries and router replicas are the high-value answer.

## Phase 4 — Analysis and Reporting

**Severity grading** (used by the 2026-11-24 report):

- 🔴 ongoing or unresolved, with outage potential (e.g. a NotReady flap
  whose root cause is unknown and could recur).
- 🟠 confirmed defect or persistent pressure to fix in the next change
  window (config bugs, chronic eviction pressure, tight disks).
- 🟡 noise / misconfiguration / user-workload fixes (permanent false
  positive alerts, broken user apps).
- ℹ️ context with no action (timelines, healthy subsystems, baselines).

For each finding report: **evidence** (exact numbers, timestamps, paths,
metrics), **impact**, and a concrete **recommended action** — and, for
anything resolved-by-then, the _state_ (reproduced / ongoing / historical).

**Snapshot-vs-live delta.** Always compare MG (T0) against live (T1) for
namespaces, pods, alerts, and etcd. Drift is expected (Jobs finish,
transient namespaces disappear, reloads happen in the gap) — report deltas
as _corroboration or drift_, never as findings in their own right.

**Reading eviction pressure.** Node conditions (`MemoryPressure`,
`DiskPressure`) use fixed thresholds and can stay `False` while the kubelet
eviction loop spins constantly — the loop's soft threshold is crossed while
the condition's (stricter) threshold is not. Real pressure is established by
the combination of: (a) kubelet `cannot evict a critical pod` churn in
logs, (b) PSI (`avg10/60/300`, sampled several times — pressure ebb and
flow), (c) descheduler eviction counters, (d) 24 h min/avg/max of
available memory per node. Check imagefs (`/var/lib/containers`)
separately — it can be the tight resource on a _different_ node than the
worst memory PSI.

**Reading PDB alerts.** The standard `PodDisruptionBudgetAtLimit` rule
fires whenever `currentHealthy == desiredHealthy` — structurally _always
true_ for single-replica PDBs with `minAvailable: 1` (all CNPG
`*-primary` PDBs). Such alerts are permanent false positives; check the
condition's `lastTransitionTime` before assuming recency. The
`PodDisruptionBudgetLimit` rule (`currentHealthy < desiredHealthy`) is the
one that signals a real budget breach. Note the new PDB status field names
(`currentHealthy`, `expectedPods`, `disruptionsAllowed`; the legacy
`currentDisruptions`/`expectedHealthy` are gone and read as null).

**Alertmanager port map (tenancy-era).** The MCP `alertmanager_url` must
target the _Service_ web port **9094**, not pod port 9095 (the
kube-rbac-proxy TLS sidecar): 9093 = AM web (loopback only), 9094 = cluster
gossip (pod) / `web` Service port, 9095 = TLS proxy (pod), 9092 = tenancy,
9097 = metrics. The MCP NetworkPolicy's egress **port 9095** is correct and
must not be changed — OVN DNAT rewrites Service port 9094 → target port
9095, so the policy speaks in target ports.

**Never cite `probe_http` 400s** with empty headers as evidence — they are
a probe artifact against Go TLS listeners (see Phase 3).

## Post-Remediation Follow-ups

The 2026-11-24 deep dive ([report](../notes/cluster-health/)) produced
three in-repo fixes. Their state, and the manual steps they still require:

| Finding                                                            | Fix                                                                                                                                                    | PR   | Manual follow-up                                                   |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---- | ------------------------------------------------------------------ |
| F2 — MCP `alertmanager_url` at pod port 9095                       | one line: 9095 → 9094 in `okd/mcp-server/base/config.toml`                                                                                             | #866 | none (auto-sync); verify MCP `get_alerts` returns data after merge |
| F4 — 11 × `PodDisruptionBudgetAtLimit` noise                       | black-hole receiver + first-in-tree route in the GitOps-managed `alertmanager-main` Secret (`okd/openshift-monitoring/overlays/okd/alertmanager.yaml`) | #868 | **manual app sync, then delete six silences** (below)              |
| F5 — `CNPGNoRecentBackup` on clair (batch-workload false positive) | 24 h window for `job="quay/cnpg-clair"`; strict 1 h kept for all other clusters                                                                        | #867 | delete two silences (below)                                        |

### F4: after #868 merges

1. **Sync the app manually** — the `openshift-monitoring` ArgoCD app has
   no `automated` sync policy: `argocd app sync openshift-monitoring`.
2. **Verify the chain**: the `alertmanager-main` Secret matches the
   rendered overlay → the in-cluster controller regenerates
   `alertmanager-main-generated` (≤ 1 min — a probe edit of the source
   Secret propagated end-to-end in under a minute on 2026-11-24) → the
   pod's config-reloader reloads Alertmanager.
3. **Delete the six user silences** that masked the alerts. They were
   created 2026-02/03 with **typo'd end years** (3026/3029 — presumably
   meant 2027) and would otherwise keep masking for ~a century. Delete via
   the AM v2 API (port-forward the pod's 9093 — see Phase 3):
   `curl -XDELETE http://127.0.0.1:9093/api/v2/silences/<id>`:

   | ID (prefix)  | Scope                                                                                       | end as created |
   | ------------ | ------------------------------------------------------------------------------------------- | -------------- |
   | `5289701e-…` | quay / `clair-primary`                                                                      | 3026-02-20     |
   | `40250d44-…` | grafana / `grafana-primary`                                                                 | 3026-03-05     |
   | `d3ec3618-…` | homeassistant / `homeassistant-primary`                                                     | 3026-03-05     |
   | `fd3bbd64-…` | immich / `immich-primary`                                                                   | 3026-03-05     |
   | `abb5843a-…` | stackrox / `stackrox-primary`                                                               | 3029-03-05     |
   | `cc8da268-…` | regex `poddisruptionbudget=~.*-primary` (covers the six clusters without a per-PDB silence) | 3026-03-06     |

   **Do not delete** `6cd2facf-…` (kubevirt PDB silences, owned by the
   `hyperconverged-cluster-operator`) or `61244d47-…` (silences a _real_
   `PodDisruptionBudgetLimit` breach on `clair-set-00` — a separate,
   explicit decision, and unaffected by the #868 route).

### F5: after #867 merges

Delete the two clair silences (both match `job=quay/cnpg-clair`):
`a0a135e6-…` (until 2027-04-24; matches **every** alert from the job) and
`5e0062ed-…` (until **4026**-04-06 — typo'd year; matches
`CNPGNoRecentBackup` on `clair-.*` pods).

### KCM rule patch — do not build procedures around it

The stock `PodDisruptionBudgetAtLimit` rule lives in the
`kube-controller-manager-operator` PrometheusRule. Manually patching its
`expected_pods > 0` to `> 1` makes the 11 alerts _resolve at the source_ —
but the `cluster-version-operator` **reverts manual edits within minutes**,
with or without an upgrade (observed 2026-11-24: applied 19:03:50Z →
reverted by 19:33Z; re-applied 19:47:37Z → reverted 19:50:35Z;
`managedFields` names `cluster-version-operator` as the manager). The
operator reverts the rule on its own reconcile, so there is no durable
"re-apply after OKD upgrade" story. Treat the patch as a short-lived
cosmetic mitigation (clean dashboards for a few minutes to an hour) only.
The durable suppression is the #868 black-hole route: it lives in the
GitOps-managed Secret, which OKD upgrades do not touch, and it keeps
dropping the notifications even while the operator flips the rule's state.

Corollary for dashboards: after the #868 sync, the 11 alerts are no longer
_notified_, but they will still show as **firing** in Prometheus/Alertmanager
(the rule is unchanged, and the masking silences are deleted) — expect that
until the stock rule is fixed upstream.

## Pitfalls Learned

- **zsh does not word-split**: `for p in "a b"; do set -- $p; …` silently
  makes `$1` the whole string. Run multi-value loops in `bash` (or use
  `${=p}`).
- **`jq` `// 0` (or `// "-"`) masks `null`** — with the new PDB status
  format this makes every PDB look like it has zero disruptions. Print raw
  status first, then interpret.
- **MG host logs lag and can be stale across cluster generations** (dead
  hostnames) and dmesg may be empty — verify actual coverage timestamps
  immediately after collection and say so in the report.
- **Take the MG early.** This run's MG was taken ~90 min after the incident
  and still missed the host-side cause (logs rotate).
- **MCP range queries return summaries only** (min/avg/max, no
  timestamps) — bisect windows to localize events.
- **MCP instant queries reject bare metric names** (need a label matcher);
  `list_metrics` rejects bare `.*`.
- **Code Mode parsing**: tool outputs are JSON strings or tables; guard
  method calls on parsed values (objects masquerade as arrays → "The
  called value is not a function").
- **`pods_list` ignores the namespace argument** (use
  `pods_list_in_namespace`); `resources_list` needs fully versioned
  apiVersions.
- **`node_collector_evictions_total` is registered but empty** — don't
  build eviction analysis on it.
- **`cluster-version-operator` reverts manual edits** to the
  `kube-controller-manager-operator` PrometheusRule within minutes —
  "patch a stock rule until the next upgrade" is not a viable mitigation
  (see Post-Remediation Follow-ups).
- **AlertmanagerConfig CRs are inert on this build.** The in-pod config
  generator is a vanilla prometheus-operator 0.93.1 that only watches the
  mounted config files (rewriting them on a fixed ~3-min cycle); it never
  merges AMC specs — verified empirically (a test AMC in `grafana` never
  reached the generated config) — and the alertmanager ServiceAccount has
  no RBAC for `alertmanagerconfigs`. Extend the `alertmanager-main` Secret
  via the `okd/openshift-monitoring` overlay instead.
- **Alertmanager v2 API**: `POST /api/v2/silences` matchers require
  `isRegex` (sending `type` instead is rejected with code 602);
  `GET /api/v2/alerts` returns a bare JSON list, not
  `{"alerts": [...]}`.
- **`kubectl delete` prompts interactively** in this kubectl build even
  with `--force --grace-period=0` — in a non-tty the prompt cancels the
  deletion; pipe `yes |` to force through.
- **Existing silences carry typo'd end years** (3006–4026; the HCO
  kubevirt one is an intentional "forever" in 3000). Always check `endsAt`
  before assuming a silence has expired — or will.

## Verification Checklist

After applying fixes (or closing an incident), confirm:

- [ ] MCP `get_alerts` / `get_silences` return data (after the F2 port fix).
- [ ] Affected node(s): no new `Failed to update lease` entries in the
      kubelet log over the next hour; Ready condition stable.
- [ ] Descheduler quiet: `descheduler:node:eviction_count:10m == 0` on the
      affected nodes; kubelet PSI `avg10/60/300` back to ~0 at repeated
      samples.
- [ ] _Notifying_ alerts back to baseline. Pre-remediation the noise was
      11 × `PodDisruptionBudgetAtLimit` + 1 × `CNPGNoRecentBackup`. After
      #867 the clair alert resolves at the source; after the #868 sync the
      AtLimit alerts are no longer _notified_ (black-hole route) — but they
      may still show as firing in Prometheus, because the stock rule is
      unchanged and the `cluster-version-operator` reverts any manual patch
      within minutes (see Post-Remediation Follow-ups). Expect ~0–1
      notifying alerts once both PRs are merged and synced.
- [ ] etcd 3/3 healthy, no alarms; ClusterOperators all converged.
- [ ] User-workload alerts from the last report (Velero, liveness, …) have
      cleared or are explicitly accepted.
