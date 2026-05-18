# Agent Instructions

This file is the entry point for AI agents working in this repository. It
mirrors the HomeLab skill at [SKILL.md](SKILL.md). Read both before acting.

## TL;DR

- This repo manages a bare-metal **OKD** cluster (3 control-plane + workers +
  GPU node) and an edge **MicroShift** node (Raspberry Pi).
- Applications are deployed via **ArgoCD GitOps** from [kubernetes/](kubernetes/).
- Bare-metal and VM provisioning is via **Ansible** ([ansible/](ansible/)) and
  the **OKD agent-based installer** ([okd/](okd/)).
- The wrapper script [main.bash](main.bash) is the primary developer entry
  point for lint/validation tasks.
- Kubernetes manifest, Helm, and Kustomize tasks must follow the
  [Kubernetes (KubeShark) skill](.agents/skills/kubernetes-skill/SKILL.md).

## Repository Map

| Path                                                               | Purpose                                                                 |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| [ansible/](ansible/)                                               | Playbooks for servers, MicroShift, desktops, and VS Code hosts          |
| [containers/](containers/)                                         | Custom container images (`toolbox`, `gpu-toolbox`, `udi`, `apache-php`) |
| [kubernetes/](kubernetes/)                                         | All cluster apps; GitOps source for ArgoCD                              |
| [kubernetes/argocd/applications/](kubernetes/argocd/applications/) | ArgoCD `Application` registrations (one YAML per app)                   |
| [machineConfigs/](machineConfigs/)                                 | Ignition / preseed configs for OS provisioning                          |
| [okd/](okd/)                                                       | OKD agent-based installer configs (`agent-config`, `install-config`)    |
| [tekton/](tekton/)                                                 | Tekton pipelines and tasks (base + overlays)                            |
| [terraform/](terraform/)                                           | GCP + KVM Terraform modules; integrates with Vault                      |
| [vms/](vms/)                                                       | KubeVirt VM definitions                                                 |
| [scripts/](scripts/)                                               | One-off helper scripts                                                  |
| [notes/](notes/)                                                   | Scratchpad and manual procedures — **not** authoritative                |
| [sandbox/](sandbox/)                                               | Throwaway experiments                                                   |
| [main.bash](main.bash)                                             | Wrapper for ansible, kustomize fixes, overlay validation                |

## Cluster Authentication

Always set `KUBECONFIG` explicitly before any `kubectl`, `oc`, `helm`, or
`kustomize` invocation:

- OKD: `export KUBECONFIG=$HOME/.kube/okd`
- MicroShift: `export KUBECONFIG=$HOME/.kube/microshift`

Both kubeconfigs grant **cluster-admin**. Default to read-only commands
(`get`, `describe`, `--dry-run=client`, `kustomize build`) when exploring.
Confirm with the user before any `apply`, `delete`, `patch`, `scale`,
`drain`, or `cordon`.

## Conventions

### Kubernetes manifests

- Layout per app: `kubernetes/<app>/{base,overlays/<cluster>}` with a
  `kustomization.yaml` at each level. Some apps add `components/` for
  reusable patches.
- Active overlays: `okd`, `microshift`, `k3s` (legacy). Pick the one
  matching the target cluster.
- Register new apps in [kubernetes/argocd/applications/](kubernetes/argocd/applications/)
  as `<app>.yaml` and include them in the local `kustomization.yaml`.
- After editing any `kustomization.yaml`, run
  `./main.bash kustomize_fix --dir kubernetes/<app>` (or `--all`) to apply
  `kustomize edit fix`, prepend `---`, and prettier-format.
- Secrets: prefer **External Secrets Operator** (`ExternalSecret` pulling
  from Vault via the cluster `ClusterSecretStore` — see
  [kubernetes/external-secrets-operator/](kubernetes/external-secrets-operator/)).
  Fall back to **argocd-vault-plugin** placeholders (`<path:...#key>`) only
  when ESO cannot express the requirement. Never commit plaintext secrets.
  Overlay validation still requires `VAULT_ADDR` and `VAULT_TOKEN` for AVP
  placeholders that remain.
- Validation: `./main.bash test_overlays` runs `kubectl kustomize` →
  `argocd-vault-plugin` → `kubeconform -strict` against a local
  `../kubernetes-json-schema/` checkout.

### Manifest authoring rules

When writing or reviewing Kubernetes resources, follow the
[Kubernetes (KubeShark) skill](.agents/skills/kubernetes-skill/SKILL.md).
Its failure-mode workflow and Conditional Reference Retrieval take
precedence over generic Kubernetes guidance. OKD-specific patterns
(SecurityContextConstraints, `Route`, arbitrary UID images) apply here —
load the `openshift-patterns` CRR reference when touching them.

### Ansible

- Inventory: [ansible/inventory](ansible/inventory). Config:
  [ansible/server.cfg](ansible/server.cfg). Galaxy deps:
  [ansible/requirements.yml](ansible/requirements.yml).
- Entry points: `servers.yaml`, `microshift.yaml`, `desktop.yaml`,
  `laptop.yaml`, `vscode-server.yaml`.
- Standard invocation:
  `ansible-playbook -i ansible/inventory --ask-become-pass --ask-pass ansible/<playbook>.yaml`
  (or `./main.bash ansible` for the default servers run).
- `ansible-lint` runs in pre-commit; keep playbooks passing.

### Shell, YAML, Markdown

- pre-commit hooks are authoritative ([.pre-commit-config.yaml](.pre-commit-config.yaml)):
  `gitleaks`, `shellcheck`, `yamllint`, `markdownlint`, `prettier`,
  `ansible-lint`, `checkov_diff`, and conventional-commit messages.
- Shell scripts use `set -o errexit -o nounset -o pipefail` and
  `shopt -s failglob` (see [main.bash](main.bash) for the template).
- YAML indent is 2 spaces; `---` document marker required at top of files
  (enforced by `kustomize_fix`).
- Commit messages must follow Conventional Commits (`feat:`, `fix:`,
  `chore:`, `build(deps):`, `docs:`, ...).

### Renovate

Pinned versions in shell scripts, pre-commit hooks, manifests, and
Helm/Kustomize inputs are kept up to date by Renovate. Preserve the
`# renovate: datasource=...` comments above pinned versions.

## Common Tasks

- Add a Kubernetes app — see [README.md](README.md#deploying-a-new-app).
- Run the central wrapper — `./main.bash <function>` (`ansible`,
  `kustomize_fix`, `test_overlays`, `test_overlays_k3s`,
  `stateful_workload_stop`, ...).
- Re-validate manifests — `./main.bash test_overlays` (requires Vault env).
- Drain a node — `oc adm drain <node> --delete-emptydir-data --ignore-daemonsets --force`
  (confirm with the user first).
- Suspend stateful workloads for maintenance —
  `./main.bash stateful_workload_stop`.

## Related Skills

- [Kubernetes (KubeShark)](.agents/skills/kubernetes-skill/SKILL.md) —
  production-grade Kubernetes manifest, Helm, and Kustomize guidance with a
  failure-mode workflow and Conditional Reference Retrieval. Activate for any
  Kubernetes resource design or review.
- [HomeLab SKILL](SKILL.md) — canonical version of this document, also
  surfaced under [.agents/skills/homelab/SKILL.md](.agents/skills/homelab/SKILL.md).

## Out of Scope

- [notes/](notes/) and [sandbox/](sandbox/) are scratch areas. Read for
  context if helpful, but never treat their YAML as the source of truth and
  do not deploy from them.
- `.git/`, `img/`, `CHANGELOG.md` (auto-maintained) — do not edit unless
  explicitly requested.
