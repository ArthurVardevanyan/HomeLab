---
name: homelab
description: Operational conventions for the HomeLab repository. Activates for any task that interacts with this repo's OKD or MicroShift clusters, applies manifests, runs Ansible against the fleet, or modifies cluster state. Also indexes other project-local skills.
---

# HomeLab Skill

Operational conventions for this HomeLab repository. Read this in full before
acting on cluster, manifest, or Ansible changes. The companion file
[AGENTS.md](AGENTS.md) expands on directory layout and common tasks.

## Related Skills

- [Kubernetes (KubeShark)](.agents/skills/kubernetes-skill/SKILL.md) —
  production-grade Kubernetes manifest, Helm, and Kustomize guidance with a
  failure-mode workflow and Conditional Reference Retrieval. Required for any
  Kubernetes resource design, review, or refactor. OKD-specific patterns
  (SCCs, Routes, arbitrary UID images) live in its `openshift-patterns` CRR
  reference.

## Cluster Inventory

| Cluster    | Distribution        | Nodes                                                | Storage   | KUBECONFIG               |
| ---------- | ------------------- | ---------------------------------------------------- | --------- | ------------------------ |
| OKD        | OKD 4.22 (SCOS 10)  | 3 control-plane (`server-1/2/3`) + workers + `gpu-1` | Rook-Ceph | `$HOME/.kube/okd`        |
| MicroShift | MicroShift on RPi 5 | Single edge node (PiHole, edge DNS)                  | Local     | `$HOME/.kube/microshift` |

GitOps: ArgoCD reconciles [kubernetes/](kubernetes/) into both clusters via
per-app overlays (`overlays/okd`, `overlays/microshift`).

## Cluster Authentication

Select the target cluster by exporting `KUBECONFIG` before any `kubectl`,
`oc`, `helm`, `kustomize`, or `argocd` call:

- OKD: `export KUBECONFIG=$HOME/.kube/okd`
- MicroShift: `export KUBECONFIG=$HOME/.kube/microshift`

Both kubeconfigs grant **cluster-admin**. Caution rules:

- Prefer read-only commands (`get`, `describe`, `--dry-run=client`,
  `kustomize build`) when exploring.
- Confirm with the user before any mutating action: `apply`, `delete`,
  `patch`, `scale`, `drain`, `cordon`, `rollout restart`, `evict`.
- Never `oc adm` or `kubectl exec` into a production workload without
  explicit user confirmation.
- Mutations to ArgoCD-managed resources will be reverted on next sync — the
  correct fix is almost always a PR to [kubernetes/](kubernetes/), not a
  live `kubectl` change.

## Repository Workflow

### Adding or editing a Kubernetes app

1. Place manifests under `kubernetes/<app>/base/` and per-cluster overlays
   under `kubernetes/<app>/overlays/{okd,microshift}/`.
2. Register the app in [kubernetes/argocd/applications/](kubernetes/argocd/applications/)
   as `<app>.yaml` and add it to the local `kustomization.yaml`.
3. Run `./main.bash kustomize_fix --dir kubernetes/<app>` to apply
   `kustomize edit fix`, prepend the `---` document marker, and
   prettier-format.
4. Validate with `./main.bash test_overlays` (requires `VAULT_ADDR` and
   `VAULT_TOKEN`; runs `argocd-vault-plugin` + `kubeconform -strict` against
   a sibling `../kubernetes-json-schema/` checkout).
5. Follow the [Kubernetes (KubeShark) skill](.agents/skills/kubernetes-skill/SKILL.md)
   for resource design (security context, probes, resources, RBAC,
   NetworkPolicy, rollout strategy).

### Secrets

- **Prefer [External Secrets Operator](kubernetes/external-secrets-operator/)**
  for any new secret: declare an `ExternalSecret` (or `ClusterExternalSecret`)
  that pulls from Vault via the configured `ClusterSecretStore`. This keeps
  the secret reconciled, rotatable, and visible as a first-class Kubernetes
  resource.
- Fall back to **argocd-vault-plugin** placeholders (`<path:secret/data/...#key>`)
  only when ESO cannot express the requirement (e.g., templated values
  injected into a non-Secret field, or bootstrap manifests that must render
  before ESO is available).
- Never commit plaintext secrets, kubeconfigs, tokens, or `.env` files.
  `gitleaks` runs in pre-commit and CI.

### Ansible

- Entry playbooks: `ansible/servers.yaml`, `microshift.yaml`, `desktop.yaml`,
  `laptop.yaml`, `vscode-server.yaml`.
- Inventory: [ansible/inventory](ansible/inventory).
- Standard invocation:
  `ansible-playbook -i ansible/inventory --ask-become-pass --ask-pass ansible/<playbook>.yaml`
  (the `./main.bash ansible` helper runs `servers.yaml`).
- `ansible-lint` must pass; preserve idempotency.

### OKD provisioning

- [okd/](okd/) holds `agent-config.yaml` and `install-config.yaml` for the
  OKD agent-based installer.
- [machineConfigs/](machineConfigs/) holds Ignition and preseed configs for
  bare-metal OS provisioning.
- Treat both as bootstrap inputs; changes are rare and high-risk — require
  explicit user confirmation.

### Lint and formatting

`pre-commit` is authoritative ([.pre-commit-config.yaml](.pre-commit-config.yaml)):

- `gitleaks`, `shellcheck`, `yamllint`, `markdownlint`, `prettier`,
  `ansible-lint`, `checkov_diff`
- Commit messages must satisfy `conventional-pre-commit`
  (`feat:`, `fix:`, `chore:`, `build(deps):`, `docs:`, ...).

YAML rules: 2-space indent, `---` document marker at top, no line-length
limit. Shell scripts: `set -o errexit -o nounset -o pipefail` and
`shopt -s failglob`; see [main.bash](main.bash).

### Renovate

Pinned versions (shell scripts, pre-commit, manifests, Helm/Kustomize
inputs) are kept current by Renovate. Preserve `# renovate: datasource=...`
comments directly above the pinned version line.

## main.bash Reference

The wrapper script exposes these functions; invoke as `./main.bash <fn>`:

| Function                  | Purpose                                                          |
| ------------------------- | ---------------------------------------------------------------- |
| `ansible`                 | Run `ansible/servers.yaml`                                       |
| `kustomize_fix --all`     | Run `kustomize edit fix` across the whole repo, then prettier    |
| `kustomize_fix --dir <d>` | Same, scoped to one directory                                    |
| `test_overlays`           | Build all OKD overlays through AVP → `kubeconform -strict`       |
| `test_overlays_k3s`       | Same for `overlays/k3s` (legacy clusters)                        |
| `stateful_workload_stop`  | Suspend CronJobs and scale stateful apps to zero for maintenance |

## Out of Scope

- [notes/](notes/) and [sandbox/](sandbox/) are scratch. Read for context;
  do not deploy from them and do not treat their YAML as authoritative.
- `CHANGELOG.md` is auto-maintained; do not hand-edit.
- `img/` holds documentation assets only.
