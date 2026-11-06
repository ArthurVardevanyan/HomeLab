# OpenShift MCP Server

## Table of Contents

- [OpenShift MCP Server](#openshift-mcp-server)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Render the Helm Chart](#render-the-helm-chart)
  - [Configuring Toolsets](#configuring-toolsets)
  - [Deploy](#deploy)
  - [Authentication](#authentication)
    - [Zitadel App](#zitadel-app)
    - [Cluster OIDC Configuration](#cluster-oidc-configuration)
    - [Vault Setup](#vault-setup)
    - [opencode.json](#opencodejson)
  - [High Availability](#high-availability)
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
  -f okd/mcp-server/values.yaml --skip-tests \
  | python3 -c "
import sys, re
yaml_doc=''
for line in sys.stdin:
    if line.startswith('# Source:'): continue
    yaml_doc+=line
docs=yaml_doc.split('\\n---\\n')
for d in docs:
    k=re.search(r'^kind: (\\S+)',d.strip(),re.M).group(1)
    n={'Deployment':'deployment','ConfigMap':'config-map','ServiceAccount':'service-account','ClusterRoleBinding':'cluster-role-binding','Service':'service','Pod':'pod'}.get(k,k).lower()+'.yaml'
    open(f'okd/mcp-server/base/{n}','w').write('---\\n'+d.strip()+'\\n')
    print(n, k)
"
```

## Configuring Toolsets

`okd/mcp-server/values.yaml` controls the toolsets via `config.toolsets`.
All 10 available toolsets are enabled by default:
`config`, `core`, `helm`, `kcp`, `kubevirt`, `metrics`, `netedge`, `openshift`,
`ossm`, `tekton`.

To narrow toolsets, edit `okd/mcp-server/values.yaml`:

```yaml
config:
  toolsets:
    - core
    - netedge
```

Then re-render per the section above.

## Deploy

Managed by ArgoCD (`openshift-mcp-server` Application). Manual:

```bash
export KUBECONFIG=$HOME/.kube/okd
kubectl kustomize okd/mcp-server/overlays/okd | kubectl apply --server-side -f -
```

## Authentication

The MCP server supports OAuth-based authentication to restrict access to
verified users and enable per-user cluster access.

### Zitadel App

A new Zitadel application (`okd-mcp`) is added to the `okd` project in
[`terraform/homelab/zitadel_okd.tf`](/terraform/homelab/zitadel_okd.tf).
It is a native app using authorization code with PKCE (public client).

```hcl
resource "zitadel_application_oidc" "okd_mcp" {
  project_id = zitadel_project.okd.id
  org_id     = zitadel_org.zitadel.id

  name = "okd-mcp"
  redirect_uris = ["http://localhost:*"]
  response_types               = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types                  = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  app_type                     = "OIDC_APP_TYPE_NATIVE"
  auth_method_type             = "OIDC_AUTH_METHOD_TYPE_NONE"
  version                      = "OIDC_VERSION_1_0"
  clock_skew                   = "0s"
  dev_mode                     = true
  access_token_type            = "OIDC_TOKEN_TYPE_JWT"
  access_token_role_assertion  = false
  id_token_role_assertion      = false
  id_token_userinfo_assertion  = true
  additional_origins           = []
  skip_native_app_success_page = true
}
```

The Terraform resource writes the client secret to Google Secret Manager.
Copy the client ID to Vault for the cluster `Authentication` config.

### Cluster OIDC Configuration

The `okd/okd-configuration/base/authentication.yaml` file is updated to
include the MCP client ID in `issuer.audiences` so the kube-apiserver
accepts its JWTs for per-user passthrough.

### Vault Setup

The client ID must be added to Vault under the path
`secret/data/homelab/zitadel/okd-mcp` with key `client_id`.
The cluster `Authentication` config uses the placeholder
`<path:secret/data/homelab/zitadel/okd-mcp#client_id>` to reference it.

### opencode.json

The `openshift-mcp` entry in `opencode.json` requires the OAuth `clientId`:

```json
"openshift-mcp": {
  "type": "remote",
  "url": "https://mcp.okd.homelab.arthurvardevanyan.com/mcp",
  "enabled": false,
  "oauth": {
    "clientId": "<your-zitadel-mcp-client-id>"
  }
}
```

After setting up Vault, use `opencode mcp auth openshift-mcp` to
authenticate. The server will use the token's identity to make cluster
API calls (per-user passthrough mode).

## High Availability

The MCP server is deployed as a singleton because sessions are in-memory
per pod. True HA would require `extraArgs: [--stateless]` in the chart
`values.yaml` plus `replicaCount: 2`, but:

- `stateless` disables tool/prompt change notifications.
- The chart does not pass `extraArgs` to the container by default,
  requiring a patch in `base/deployment-patch.yaml`.
- Sessions are ephemeral and will be lost on pod restart.

Until a stateless mode is implemented and tested, the server should
remain a singleton with a single route and no HA.

## Notes

- Separate from the Lightspeed-operator managed `openshift-mcp-server` in
  the `openshift-lightspeed` namespace, which OLSConfig uses.
- The `clusterProvider` is set to `openshift-mcp` so that OpenShift's own
  tools (like `oc` CLI tools) become available via the `openshift` toolset.
- The server uses its ServiceAccount, bound to the `view` ClusterRole.
- The route has no authentication by default. Verify exposure is acceptable
  (LAN only) before enabling the `openshift-mcp` entry in `opencode.json`.
