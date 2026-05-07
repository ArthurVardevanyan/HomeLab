# gen-resource-inclusions

Scans one or more directories for Kubernetes YAML files and prints a formatted `resourceInclusions` block suitable for pasting into an ArgoCD `ArgoCD` CR.

## Usage

```sh
go run -C scripts/gen-resource-inclusions . [flags] <dir> [dir...]
```

| Flag            | Description                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------ |
| `-write <file>` | Update `resourceInclusions` in an ArgoCD CR YAML file in-place instead of printing to stdout     |
| `-skip-groups`  | Comma-separated list of additional API groups to exclude (e.g. `tekton.dev,triggers.tekton.dev`) |

### Examples

Print inclusions from the HomeLab `kubernetes/` directory:

```sh
go run -C scripts/gen-resource-inclusions . kubernetes/
```

Update the main ArgoCD instance in-place:

```sh
go run -C scripts/gen-resource-inclusions . -write kubernetes/argocd/base/argocd.yaml kubernetes/ tekton/
```

Update the `argocd-apps` instance from the three app repos:

```sh
go run -C scripts/gen-resource-inclusions . \
  -write kubernetes/argocd/apps/argocd-apps.yaml \
  -skip-groups tekton.dev,triggers.tekton.dev \
  ../FinanceTracker/ \
  ../Analytics-for-Spotify/ \
  ../ArthurVardevanyan-com/
```

## Excluded Groups

The following API groups are always excluded from the output:

- `packages.operators.coreos.com`
- `kustomize.config.k8s.io`

To add or remove exclusions, edit the `skipGroups` / `skipKinds` maps in `main.go`.
