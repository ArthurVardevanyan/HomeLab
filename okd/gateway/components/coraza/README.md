# Coraza CRS Update Script

`update-crs.sh` regenerates the OWASP CRS ConfigMaps and Secret under
`rules/owasp-crs/`, and optionally updates `rules/crs-setup/` and
`rules/recommended-conf/`, from upstream source repositories.

## Usage

```sh
okd/gateway/components/coraza/update-crs.sh [--source wasm|crs|coraza] [--tag <tag>] [--commit <sha>] [--repo-url <url>]
```

### Options

| Flag               | Description                                                                                                                                                            |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--source wasm`    | _(default)_ Pull rules from [networking-incubator/coraza-proxy-wasm](https://github.com/networking-incubator/coraza-proxy-wasm) — pre-validated for Envoy WASM runtime |
| `--source crs`     | Pull rules from [coreruleset/coreruleset](https://github.com/coreruleset/coreruleset) — official upstream CRS releases                                                 |
| `--source coraza`  | Update `rules/recommended-conf/configmap.yaml` only from [corazawaf/coraza](https://github.com/corazawaf/coraza)                                                       |
| `--tag <tag>`      | Checkout a specific release tag (e.g. `v4.26.0`). Defaults to the latest tag if omitted                                                                                |
| `--commit <sha>`   | Checkout a specific commit SHA instead of a tag                                                                                                                        |
| `--repo-url <url>` | Override the source repository URL                                                                                                                                     |

## Examples

```sh
# Latest release from coraza-proxy-wasm (default)
okd/gateway/components/coraza/update-crs.sh

# Official CRS release by tag
okd/gateway/components/coraza/update-crs.sh --source crs --tag v4.26.0

# Specific commit from coraza-proxy-wasm
okd/gateway/components/coraza/update-crs.sh --source wasm --commit abc1234

# Update recommended-conf only from a specific coraza release
okd/gateway/components/coraza/update-crs.sh --source coraza --tag v3.3.0
```

## What Gets Updated

| Source         | Files modified                                                                                                             |
| -------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `wasm` / `crs` | `rules/owasp-crs/*/configmap.yaml` + `kustomization.yaml`, `rules/owasp-crs/secret.yaml`, `rules/crs-setup/configmap.yaml` |
| `coraza`       | `rules/recommended-conf/configmap.yaml` only                                                                               |

### Notes

- Existing per-rule directories under `rules/owasp-crs/` are **fully replaced** on each run.
- Response body inspection rules (`response-950` through `response-955`) are generated but commented out in `owasp-crs/kustomization.yaml` — they are not supported in Envoy WASM mode.
- If `prettier` is installed it will format all generated YAML files automatically.
