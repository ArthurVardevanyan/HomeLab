# OpenShift MCP Server

## Table of Contents

- [OpenShift MCP Server](#openshift-mcp-server)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Render the Helm Chart](#render-the-helm-chart)
  - [Deploy](#deploy)
  - [Notes](#notes)

## Overview

Red Hat OpenShift MCP Server (tech preview), deployed from the
`redhat-openshift-mcp-server` Helm chart rendered into
the split manifests in [base/](base/). Overrides live in
[values.yaml](values.yaml). It is exposed at
`https://mcp.okd.homelab.arthurvardevanyan.com/mcp` through the Gateway API
([components/gateway](components/gateway)).

## Render the Helm Chart

```bash
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update

helm template openshift-mcp-server openshift-helm-charts/redhat-openshift-mcp-server \
  --version 0.3.0 --namespace openshift-mcp-server \
  -f okd/mcp-server/values.yaml --skip-tests > /tmp/mcp-server.yaml
```

Split the output into one file per object in `base/`
(`service-account.yaml`, `config-map.yaml`, `cluster-role-binding.yaml`,
`service.yaml`, `deployment.yaml`) and drop the `# Source:` comments. Local
changes (digest-pinned image in `deployment.yaml`, security defaults in
`deployment-patch.yaml`) mean re-rendering only needs a diff against the
chart output.

## Deploy

Managed by ArgoCD (`openshift-mcp-server` Application). Manual:

```bash
export KUBECONFIG=$HOME/.kube/okd
kubectl kustomize okd/mcp-server/overlays/okd | kubectl apply --server-side -f -
```

## Notes

- Separate from the Lightspeed-operator managed `openshift-mcp-server` in the
  `openshift-lightspeed` namespace, which OLSConfig uses.
- Toolsets: `core`, `ovn-kubernetes`, `cni-diagnostics`, `netedge`. `ossm` is
  omitted because Kiali is not installed.
- The server uses its ServiceAccount, bound to the `view` ClusterRole.
- The route has no authentication. Verify exposure is acceptable (LAN only)
  before enabling the `openshift-mcp` entry in `opencode.json`.
