# Stackrox Secure

## Table of Contents

- [Stackrox Secure](#stackrox-secure)
  - [Table of Contents](#table-of-contents)
  - [TLS secret names and `helmManaged`](#tls-secret-names-and-helmmanaged)
  - [OpenShift Console Plugin (OKD overlay)](#openshift-console-plugin-okd-overlay)
    - [Why is this hand-vendored?](#why-is-this-hand-vendored)
    - [Updating the ConsolePlugin on StackRox version bumps](#updating-the-consoleplugin-on-stackrox-version-bumps)
  - [Re-vendoring the chart manifests](#re-vendoring-the-chart-manifests)

## TLS secret names and `helmManaged`

The chart picks per-component TLS secret names based on the `helmManaged`
value, which defaults to `true`. With the default, "secured cluster
certificate refresh" is enabled (`templates/_certrefresh.tpl`) and the
workloads mount Central-provisioned secrets:

| Workload            | `helmManaged=true` (chart default)        | `helmManaged=false`     |
| ------------------- | ----------------------------------------- | ----------------------- |
| `collector`         | `tls-cert-collector`                      | `collector-tls`         |
| `admission-control` | `tls-cert-admission-control`              | `admission-control-tls` |
| `sensor`            | `tls-cert-sensor` (+ legacy `sensor-tls`) | `sensor-tls`            |

Nothing in this repository creates the `tls-cert-*` secrets: they are written
at runtime by Sensor after it registers with Central using a cluster
registration secret (CRS). Certificates here are provisioned statically from
Vault by the ExternalSecrets in `base/secret.yaml`, under the
`<component>-tls` names. Rendering with the chart default therefore produces
manifests the cluster cannot satisfy, and pods fail with:

```text
MountVolume.SetUp failed for volume "certs" : secret "tls-cert-collector" not found
```

`components/manual-certs` patches the collector and admission-control volumes
back to the manually-managed names, and is included by every overlay (`okd`,
`sandbox`, `microshift`, `microshift-dc2`). Sensor is left alone: in refresh
mode it mounts both names as optional, so it is unaffected.

Migrating to CRS-based certificate refresh would replace
`components/manual-certs` and the cert fields in Vault; see #843 for that
conversion.

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

## Re-vendoring the chart manifests

`base/` is a `helm template` render of the upstream chart, with the
`createSecrets` templates dropped in favour of External Secrets. Only the
files that actually changed should be replaced; a full re-render also
rewrites `managedBy` and `configFingerprint` in
`overlays/<cluster>/cluster-name.yaml`, which is hand-maintained and does not
match chart defaults (`slimCollector: true`, admission control listeners
disabled).

```bash
# Target Cluster
export CLUSTER="homelab"
#   --set env.openshift=k8s

helm template -n stackrox stackrox-secured-cluster-services stackrox/stackrox-secured-cluster-services \
 -f notes/stackrox-init-bundle.yaml \
 --set scanner.disable=true \
 --set scannerV4.disable=true \
 --set clusterName="${CLUSTER}" \
 --set createSecrets=false \
 --set helmManaged=false \
 --set sensor.resources.requests.memory=125Mi \
 --set sensor.resources.requests.cpu=125m \
 --set sensor.resources.limits.memory=500Mi \
 --set sensor.resources.limits.cpu=500m   --set env.openshift=4  >/tmp/secure.yaml

 kubectl kustomize kubernetes/stackrox-secure/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

`helmManaged=false` keeps the `collector-tls`/`admission-control-tls` secret
names (see above). It also sets `managedBy: MANAGER_TYPE_MANUAL`, which
changes the cluster config fingerprint: if you let a re-render touch
`cluster-name.yaml`, update
`secret/homelab/stackrox/<cluster> #config-fingerprint` in Vault to the new
`configFingerprint`, since both the `helm-cluster-config` secret and the
sensor's `ROX_HELM_CLUSTER_CONFIG_FP` read that one field. Alternatively keep
`helmManaged=true` at render time and rely on `components/manual-certs`.
