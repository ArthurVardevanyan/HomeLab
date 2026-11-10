# Stackrox Secure

## OpenShift Console Plugin (OKD overlay)

The OKD overlay includes a `ConsolePlugin` CR that embeds ACS vulnerability
management into the OpenShift web console (vulnerability tab on Deployments,
ImageStreams, etc.).

### Why is this hand-vendored?

The upstream community Helm chart [`stackrox/stackrox-secured-cluster-services`](https://github.com/stackrox/stackrox-helm-charts) contains a
template for the ConsolePlugin, but it is gated behind `installMethod ==
operator`. Since we deploy with pure Helm manifests (no StackRox operator), the
plugin CR is never rendered by `helm template`. We therefore vendor it
manually here.

### Updating the ConsolePlugin on StackRox version bumps

1. Check the community operator fork's templates:
   [`stackrox-charts/stackrox`](https://github.com/stackrox/stackrox-helm-charts)
   → `templates/console-plugin.yaml`.
2. Diff against `kubernetes/stackrox-secure/overlays/okd/console-plugin.yaml`.
3. If the upstream `displayName`, `basePath`, or proxy aliases changed, update
   the fields in the vendored file.
4. Ensure the base overlay still exposes the required backend:
   **sensor-proxy** Service on port 443 (→ proxy-https 9444) and the
   `openshift-console` → sensor-proxy `NetworkPolicy` are present.

Enablement is managed in [`okd/okd-configuration/base/operators/console.yaml`](../../okd/okd-configuration/base/operators/console.yaml),
which GitOps-manages the cluster Console `spec.plugins` list.

---

```bash
# Target Cluster
export CLUSTER="homelab"
#   --set env.openshift=k8s

helm template -n stackrox stackrox-secured-cluster-services stackrox/stackrox-secured-cluster-services \
 -f notes/stackrox-init-bundle.yaml \
 --set scanner.disable=true \
 --set scannerV4.disable=true \
 --set clusterName="${CLUSTER}" \
 --set sensor.resources.requests.memory=125Mi \
 --set sensor.resources.requests.cpu=125m \
 --set sensor.resources.limits.memory=500Mi \
 --set sensor.resources.limits.cpu=500m   --set env.openshift=4  >/tmp/secure.yaml

 kubectl kustomize kubernetes/stackrox-secure/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
