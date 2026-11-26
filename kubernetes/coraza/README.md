# Coraza Kubernetes Operator

Vendored deployment manifests for the
[Coraza Kubernetes Operator](https://github.com/networking-incubator/coraza-kubernetes-operator)
(the upstream is a Red Hat-hosted networking-incubator project).

## Table of Contents

- [Table of Contents](#table-of-contents)
- [Deployment Model](#deployment-model)
- [Dogfood Pin (upstream `main`)](#dogfood-pin-upstream-main)
- [Rebuilding the Image](#rebuilding-the-image)
- [Re-vendoring the Manifests](#re-vendoring-the-manifests)

## Deployment Model

- `base/` holds Helm-rendered manifests plus hand-added pieces that the
  chart cannot render for GitOps: `serving-cert.yaml` (cert-manager
  supplies the ECDS/xDS serving Secret because `helm template` would mint a
  new CA on every ArgoCD sync) and the CRDs under `crds/`.
- `overlays/okd/` adds the VPA and the namespace EgressFirewall.
- Deployed by the ArgoCD app `coraza-operator`
  ([kubernetes/argocd/components/applications/okd/coraza.yaml](../argocd/components/applications/okd/coraza.yaml)).

## Dogfood Pin (upstream `main`)

We intentionally run an operator built from upstream `main` (not a tagged
release) to dogfood the EnvoyFilter + ECDS integration and the Rust
`envoy-coraza` filter ahead of the v0.6.0 release, and to give the
maintainers OpenShift/OKD test signal (upstream issue #18).

| Item         | Value                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Upstream     | `networking-incubator/coraza-kubernetes-operator`                                                                        |
| Commit       | `9793e9899cc8a81ed741194d81356f50c3dbee5a` (2026-11-19)                                                                  |
| Image        | `registry.arthurvardevanyan.com/homelab/coraza-kubernetes-operator`                                                      |
| Tag/digest   | `main-20261119-9793e98@sha256:c07bd261dae21fb1e4e29f3402ad5f933e04df8e083d354f445327426dcdf311`                          |
| Bundled wasm | `coraza-rs` v0.0.2 `envoy-coraza` with **CRS v4.30.0 embedded** (`sha256:47d107fd…`, digest-pinned by upstream Makefile) |

When upstream tags v0.6.0+, stop building: re-pin the Deployment image to
the published digest and drop this section.

## Rebuilding the Image

```sh
git clone https://github.com/networking-incubator/coraza-kubernetes-operator /tmp/coraza-op
cd /tmp/coraza-op && git checkout <upstream-sha>
make wasm.release WASM_CRS=1   # fetch digest-pinned coraza-rs artifact into internal/assets
make wasm.verify
VERSION=v0.0.0-main-<date>-<sha> CONTAINER_TOOL=podman make build.image
podman tag ghcr.io/networking-incubator/coraza-kubernetes-operator:v0.0.0-main-<date>-<sha> \
  registry.arthurvardevanyan.com/homelab/coraza-kubernetes-operator:main-<date>-<sha>
podman push registry.arthurvardevanyan.com/homelab/coraza-kubernetes-operator:main-<date>-<sha>
```

Update the image tag **and digest** in `base/deployment.yaml`, plus the pin
table above.

## Re-vendoring the Manifests

```sh
helm template coraza-kubernetes-operator charts/coraza-kubernetes-operator -n coraza-system \
  --set openshift.enabled=true \
  --set istio.revision=openshift-gateway \
  --set metrics.serviceMonitor.enabled=true \
  --set image.repository=registry.arthurvardevanyan.com/homelab/coraza-kubernetes-operator \
  --set image.tag=main-<date>-<sha> \
  --set tls.generate=false
```

Split the render into `base/` (see existing file split), copy the four CRDs
from `charts/coraza-kubernetes-operator/crds/` into `base/crds/`, then run
`k8s-gitops-ci kustomize-fix -dir kubernetes/coraza`.
