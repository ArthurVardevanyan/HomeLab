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
  point for Ansible, VM provisioning, and OKD cluster management.
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
| [main.bash](main.bash)                                             | Wrapper for Ansible, cluster state management, and OKD provisioning     |

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
- Active overlays: `okd`, `okd-sandbox`, `okd-unas`, `sandbox`, `sno`,
  `microshift`, `microshift-unas`, `old`, `operator` (all OpenShift/OKD-based)
  and `k3s` (legacy, the only non-OpenShift target). Pick the one matching
  the target cluster.
- Register new apps in [kubernetes/argocd/applications/](kubernetes/argocd/applications/)
  as `<app>.yaml` and include them in the local `kustomization.yaml`.
- After editing any `kustomization.yaml`, run
  `k8s-gitops-ci kustomize-fix -dir kubernetes/<app>` (or `-all`) to normalize
  field ordering.
- Secrets: prefer **External Secrets Operator** (`ExternalSecret` pulling
  from Vault via the cluster `ClusterSecretStore` — see
  [kubernetes/external-secrets-operator/](kubernetes/external-secrets-operator/)).
  Fall back to **argocd-vault-plugin** placeholders (`<path:...#key>`) only
  when ESO cannot express the requirement. Never commit plaintext secrets.
  Overlay validation still requires `VAULT_ADDR` and `VAULT_TOKEN` for AVP
  placeholders that remain.
- See [CI Validation (k8s-gitops-ci)](#ci-validation-k8s-gitops-ci) for
  local iteration, scoped validation, and full-repo scans.

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

### CI Validation (k8s-gitops-ci)

- Real CI runs via `.tekton/gitops-ci.yaml`'s `gitops-ci` Task, invoking
  `k8s-gitops-ci pipeline --dirs "kubernetes/,tekton/,.tekton/,okd/"
--assume-openshift` from the sibling `../k8s-gitops-ci` repo (see
  `tekton/base/gitops-ci.yaml`).
- **Local iteration** defaults to the working-tree git diff — only changed
  files are validated. Use `--all` for a full repo scan, or `--dirs` to
  scope to specific paths:
  `k8s-gitops-ci test --dirs kubernetes/,tekton/,.tekton/,okd/ --assume-openshift --disable-checks avp`
- **Always pass `--assume-openshift`** when validating locally — it matches
  real CI and tells the sync-options check that OpenShift/OKD built-in API
  groups are guaranteed present at first sync, so those resources do **not**
  need the `SkipDryRunOnMissingResource=true` annotation. Without it you get
  spurious sync-options findings for cluster-native CRDs. (This is why
  `--assume-openshift` is required — it makes the check skip third-party
  CRDs that only exist on clusters where those operators are installed.)
- For local iteration also pass `--disable-checks avp` unless you have
  `VAULT_ADDR`/`VAULT_TOKEN` exported — otherwise AVP placeholder resolution
  fails the overlay build with unrelated "could not replace all placeholders"
  noise.
- **Scoped validation:**
  `k8s-gitops-ci test --app kubernetes/<app> --cluster <cluster> --assume-openshift --disable-checks avp`
  (repeatable flags; `--app` alone validates every overlay of that app,
  `--cluster` alone validates every app targeting that cluster).
- Before pushing, confirm the full CI scope still passes (mirrors real CI;
  defaults to reading local `test.sh` automatically — no PR needed).
- Avoid `test --all` for full-repo scans that include ansible/,
  machineConfigs/, notes/, sandbox/ — these are outside CI's actual
  `--dirs` scope and produce irrelevant noise.
- After changing `../k8s-gitops-ci` source, rebuild before testing:
  `cd ../k8s-gitops-ci && task build`.
- Some fixes require changes in **both** repos (e.g., adjusting a check's
  behavior, adding a new exemption mechanism) — check `../k8s-gitops-ci`'s
  own `AGENTS.md`/`docs/` when validation behavior itself needs to change.
- Exemptions: `test.sh` with `export EXEMPTIONS=(...)` at an app root or any
  directory with non-Kubernetes YAML — see `okd/test.sh` for a working
  example and the [exemptions skill](https://github.com/ArthurVardevanyan/k8s-gitops-ci/blob/main/.agents/skills/exemptions/SKILL.md) for the
  full reference.

### Shell, YAML, Markdown

- pre-commit hooks are authoritative ([.pre-commit-config.yaml](.pre-commit-config.yaml)):
  `gitleaks`, `shellcheck`, `yamllint`, `markdownlint`, `prettier`,
  `ansible-lint`, `checkov_diff`, and conventional-commit messages.
- Shell scripts use `set -o errexit -o nounset -o pipefail` and
  `shopt -s failglob` (see [main.bash](main.bash) for the template).
- YAML indent is 2 spaces; `---` document marker required at top of files
  (enforced by `kustomize-fix`).
- Commit messages must follow Conventional Commits (`feat:`, `fix:`,
  `chore:`, `build(deps):`, `docs:`, ...).

### Renovate

Pinned versions in shell scripts, pre-commit hooks, manifests, and
Helm/Kustomize inputs are kept up to date by Renovate. Preserve the
`# renovate: datasource=...` comments above pinned versions.

## Common Tasks

- Add a Kubernetes app — see [README.md](README.md#deploying-a-new-app).
- Run the central wrapper — `./main.bash <function>` (`ansible`,
  `stateful_workload_stop`, ...).
- Validate manifests — see [CI Validation](#ci-validation-k8s-gitops-ci).
- Drain a node — `oc adm drain <node> --delete-emptydir-data --ignore-daemonsets --force`
  (confirm with the user first).
- Suspend stateful workloads for maintenance —
  `./main.bash stateful_workload_stop`.

## Before Committing

- Validate changed files — see [CI Validation](#ci-validation-k8s-gitops-ci).
- For individual file linting, run k8s-gitops-ci linters directly:
  `k8s-gitops-ci markdownlint`, `k8s-gitops-ci prettier`, `k8s-gitops-ci shellcheck`, etc.

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
