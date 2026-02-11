# scafctl: generate-argocd-apps

This folder contains a [scafctl](https://oakwood-commons.github.io/scafctl/) solution that generates ArgoCD `Application` manifests from the repository `kubernetes/` folders.

## Purpose

- Generates ArgoCD Application YAML files into `kubernetes/argocd/applications/{cluster}/`.
- Only creates an entry for an app if `kubernetes/<app>/overlays/<cluster>` exists.
- Supports multiple clusters in a single run, driven by `.scafctl/config.yaml`.

## Usage

```bash
scafctl run solution -f .scafctl/solution.yaml
```

## How It Works

1. **Cluster discovery** — Reads the `clusters` map from `.scafctl/config.yaml` to determine which clusters to generate for and their API server URLs.
2. **Folder scanning** — For each cluster, iterates over `kubernetes/*/` directories and checks whether `kubernetes/<app>/overlays/<cluster>` exists (skipping `argocd` itself).
3. **Vault plugin detection** — Checks `.scafctl/config.yaml` `applications.<app>.vault-plugin` to determine if the app needs the `argocd-vault-plugin-kustomize` plugin.
4. **Template rendering** — Renders each Application manifest using a Go template embedded in `solution.yaml`, writing to `kubernetes/argocd/applications/<cluster>/<app>.yaml`.

## Naming Convention

- **okd** cluster: Application `metadata.name` is the app folder name (e.g. `cert-manager`).
- **All other clusters**: Application `metadata.name` is postfixed with the cluster name (e.g. `cert-manager-microshift`).

## File Structure

```text
.scafctl/
├── config.yaml      # Cluster servers and per-app vault-plugin flags
├── solution.yaml    # scafctl solution definition
├── README.md        # This file
└── templates/
    └── argocd/
        └── applications/
            └── application.yaml  # Reference template (not used at runtime)
```

## Configuration — `config.yaml`

### Clusters

Add or remove clusters under the `clusters` key. Each entry maps a cluster name to its API server URL:

```yaml
clusters:
  microshift:
    server: https://microshift.arthurvardevanyan.com:6443
  okd:
    server: https://kubernetes.default.svc
```

### Vault Plugin

To enable `argocd-vault-plugin-kustomize` for an app, add it under `applications` with `vault-plugin: true`:

```yaml
applications:
  cert-manager:
    vault-plugin: true
```

Apps not listed (or without `vault-plugin: true`) will not include the plugin block in the generated manifest.

## Overridable Parameters

The solution accepts optional `-r` parameter overrides:

| Parameter   | Default                                                       | Description                    |
| ----------- | ------------------------------------------------------------- | ------------------------------ |
| `repo`      | `https://git.arthurvardevanyan.com/ArthurVardevanyan/HomeLab` | Git repository URL             |
| `kubeDir`   | `./kubernetes`                                                | Path to kubernetes directory   |
| `outputDir` | `./kubernetes/argocd/applications`                            | Output directory for manifests |

Example:

```bash
scafctl run solution -f .scafctl/solution.yaml -r repo=https://github.com/example/repo
```
