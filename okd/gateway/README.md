# OKD Gateway

> **This directory manages Gateway API resources for OKD clusters: internal/external gateways, per-application ListenerSets, Coraza WAF, Wiretap observability, and certificates.**

## Table of Contents

- [OKD Gateway](#okd-gateway)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Gateways](#gateways)
    - [Internal gateway](#internal-gateway)
    - [External gateway](#external-gateway)
  - [App pattern](#app-pattern)
    - [Example template](#example-template)
  - [Runtime config](#runtime-config)
  - [Security](#security)
    - [Coraza WAF](#coraza-waf)
    - [AuthorizationPolicy (external)](#authorizationpolicy-external)
    - [NetworkPolicies (external)](#networkpolicies-external)
  - [Observability](#observability)
    - [Wiretap](#wiretap)
  - [Kustomize and ArgoCD wiring](#kustomize-and-argocd-wiring)
  - [Kyverno policies](#kyverno-policies)
    - [`istiod-enable-listenersets`](#istiod-enable-listenersets)
    - [`istiod-openshift`](#istiod-openshift)
    - [Cleanup when ListenerSets is GA](#cleanup-when-listenersets-is-ga)
  - [Layout](#layout)

## Overview

The gateway stack routes traffic through two Istio gateways backed by MetalLB. Application TLS ownership is delegated to per-app **ListenerSets** — each application owns its own listener and certificate via an HTTPRoute reference.

## Gateways

Both gateways live in the `openshift-ingress` namespace and share a `GatewayClass` named `openshift-default`.

### Internal gateway

- **Name:** `https-gateway`
- **Listener:** single listener on `internal.gateway.okd.homelab.arthurvardevanyan.com`
- **allowedListeners:** `from: All` — any namespace may attach a ListenerSet
- **allowedRoutes:** `namespaces.from: Same` — routes must be in the same namespace as the ListenerSet
- **Certificate:** `internal-gateway-cert`
- **Labels:** `coraza: internal-ruleset` activates the Coraza engine
- **ConfigMap:** `gw-options-internal`
- **MetalLB IP:** `10.101.9.240`

### External gateway

- **Name:** `https-gateway-external`
- **Listener:** single listener on `external.gateway.okd.homelab.arthurvardevanyan.com`
- **allowedListeners:** `from: Selector` with `matchLabels: gateway-tenancy: external`
- **allowedRoutes:** `namespaces.from: Same`
- **Certificate:** `external-gateway-cert`
- **Labels:** `coraza: external-ruleset` activates the Coraza engine
- **ConfigMap:** `gw-options-external`
- **MetalLB IP:** `10.101.9.241`

## App pattern

Each app deploys three resources:

1. **ListenerSet** — listener definition with hostname, TLS settings and `certificateRefs`
2. **Certificate** — cert-manager Certificate resource (ECDSA P-256, 45-day duration, `letsencrypt` issuer)
3. **HTTPRoute** — parentRef is the ListenerSet only (no Gateway parentRef)

### Example template

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: <app>
  namespace: <namespace>
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: https-gateway # or https-gateway-external
    namespace: openshift-ingress
  listeners:
    - name: https
      hostname: "<app>.okd.homelab.arthurvardevanyan.com"
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: Same
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: <app>-cert
---
apiVersion: networking.istio.io/v1beta1
kind: WasmPlugin
metadata:
  name: wiretap
  namespace: openshift-ingress
spec:
  url: "oci://registry.microshift.arthurvardevanyan.com/homelab/wasm-wiretap@sha256:<sha>"
  pluginConfig:
    backend: "loki"
    upstream_cluster: "outbound|9481||vlinsert-ingress-logs.openshift-ingress-logs.svc.cluster.local."
    upstream_port: 9481
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
  namespace: <namespace>
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      name: <app>
      namespace: <namespace>
  hostnames: ["<app>.okd.homelab.arthurvardevanyan.com"]
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: <service>
          port: <port>
```

Real examples live under `kubernetes/*/base/gateway/`. Find them:

```bash
grep -r "kind: ListenerSet" kubernetes/
```

## Runtime config

The `gw-options-*` ConfigMaps template gateway Pod settings. They document the design intent in their comments:

- **externalTrafficPolicy: Local** — preserves real client source IP
- **minReplicas: 3** — one pod per control-plane node via topology spread constraints
- **preStop: sleep 45** + **terminationDrainDuration: 45s** — graceful Envoy drain during shutdown
- **MetalLB L2** with `10.101.9.240` / `10.101.9.241`
- **HPA** with `150%` CPU target, `300s` scaleDown stabilization
- **VPA** with memory range only, `InPlaceOrRecreate` mode

Full values are in the ConfigMap files — `okd/gateway/components/gateway/internal/configmap.yaml` and `external/configmap.yaml`.

## Security

### Coraza WAF

Coraza rules are applied via labels on the gateway resources:

- `coraza: internal-ruleset` → Coraza engine `internal`
- `coraza: external-ruleset` → Coraza engine `external`

The rules live in `okd/gateway/components/coraza/`. See `okd/gateway/components/coraza/README.md` for the update script.

### AuthorizationPolicy (external)

`https-gateway-external-cloudflare` restricts the external gateway to Cloudflare IPs and the local network:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: https-gateway-external-cloudflare
  namespace: openshift-ingress
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: https-gateway-external
  action: ALLOW
  rules:
    - from:
        - source:
            ipBlocks:
              # Cloudflare IPs
              - 173.245.48.0/20
              - 103.21.244.0/22
              - 103.22.200.0/22
              # ... (see full file for all ranges)
```

### NetworkPolicies (external)

The external gateway has egress NetworkPolicies for DNS, Coraza cache, internet access, backends, and observability targets. They live in `okd/gateway/components/gateway/external/network-policy.yaml`.

## Observability

### Wiretap

The Wiretap component captures request and response headers and bodies via a WasmPlugin injected into the gateway, then pushes structured data to the VictoriaLogs insert endpoint.

- **WasmPlugin:** configured with `backend: "loki"` and `upstream_cluster` pointing to the VictoriaLogs Service (`vlinsert-ingress-logs.openshift-ingress-logs.svc.cluster.local.` on port `9481`).
- **ServiceEntry:** `loki-external` defines the ServiceEntry for the VictoriaLogs Service.
- **VLogs:** a `VLogs` instance is deployed in the `openshift-ingress-logs` namespace with a ServiceMonitor, VPA and NetworkPolicy.

The Wiretap configs are split into `internal` and `internet` variants under `okd/gateway/components/wiretap/configs/`. The `okd/gateway/components/wiretap/victoria-metrics/` directory contains the VictoriaLogs resources (the name is historical — it points to the VictoriaLogs insert API).

## Kustomize and ArgoCD wiring

The overlay assembles all components:

```yaml
# okd/gateway/overlays/okd/kustomization.yaml
resources:
  - ../../base
components:
  - ../../components/gateway/internal
  - ../../components/gateway/external
  - ../../components/coraza/rules
  - ../../components/coraza/engine/internal
  - ../../components/coraza/engine/external
  - ../../components/wiretap/configs/v0.0.0+/internal
  - ../../components/wiretap/configs/v0.0.0+/internet
  - ../../components/wiretap/instance/v0.0.0
  - ../../components/wiretap/victoria-metrics
```

The `okd-gateway` ArgoCD Application watches this overlay:

- **Path:** `okd/gateway/overlays/okd`
- **Sync wave:** `1`
- **Server Side Apply:** enabled

## Kyverno policies

There are two Kyverno policies in `base/`:

### `istiod-enable-listenersets`

Patches the `istiod` Deployment (`discovery` container) to set:

- `PILOT_ENABLE_ALPHA_GATEWAY_API=true`
- `PILOT_IGNORE_RESOURCES=""`

This enables ListenerSet support in OpenShift's Istio. The policy lives in `okd/gateway/base/kyverno-listenerset.yaml`.

### `istiod-openshift`

Patches the `istiod-openshift-gateway` HPA to set `minReplicas: 2`.

### Cleanup when ListenerSets is GA

When ListenerSets reaches GA and Istio's native support is available:

1. Delete the `istiod-enable-listenersets` Policy from `okd/gateway/base/kyverno-listenerset.yaml`
2. Remove it from `okd/gateway/base/kustomization.yaml`
3. Confirm no `allowedListeners` or ListenerSet parentRef issues in the gateway status

## Layout

```plaintext
okd/gateway/
├── base/                                  # Base manifests (gateway-class, PDB, VPA, Kyverno policies)
├── components/
│   ├── gateway/
│   │   ├── internal/                      # Internal gateway + cert + configmap
│   │   └── external/                      # External gateway + cert + policies
│   ├── coraza/                            # OWASP CRS rules and engine
│   └── wiretap/                           # Wasm traffic capture + VictoriaLogs
├── overlays/okd/                          # Full overlay (10 components)
└── README.md                              # This file
```
