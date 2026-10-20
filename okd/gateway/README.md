# OKD Gateway

> **This directory contains Gateway API resources for OKD clusters (internal + external gateways, ListenerSets, and certificates).**

## Architecture

- **Internal Gateway** (`internal-gateway.yaml`): Single listener on `internal.gateway.okd.homelab.arthurvardevanyan.com`. Hosts internal-only workloads.
- **External Gateway** (`external-gateway.yaml`): Single listener on `external.gateway.okd.homelab.arthurvardevanyan.com`. Hosts externally-facing applications.
- **ListenerSets**: Each application has its own ListenerSet that owns its TLS listener and certificates. HTTPRoutes reference ListenerSets exclusively (no Gateway parentRef).

## Migration from Wildcard Gateways

The previous architecture had multiple wildcard `*.arthurvardevanyan.com` listeners per gateway, each with their own certificate. This has been replaced by:

1. Single-fqdn listeners per gateway (one for internal, one for external)
2. Per-application ListenerSets with their own certificates
3. HTTPRoutes that reference ListenerSets only (no Gateway parentRef)

This eliminates wildcard certificates, reduces cert-manager load, and follows the Kubernetes Gateway API best practice of small, focused listeners.

## Istio Kyverno Policy

A Kyverno policy (`kyverno-listenerset.yaml`) patches the `istiod` Deployment to enable the `PILOT_ENABLE_ALPHA_GATEWAY_API` and `PILOT_IGNORE_RESOURCES` environment variables. This is a **temporary workaround** required for OpenShift's Istio to process ListenerSets in a multi-gateway topology.

> **⚠️ CLEANUP REQUIRED**: Once ListenerSets GA and the Istio/OKD integration stabilizes, this Kyverno policy should be removed.
>
> - Remove `PILOT_ENABLE_ALPHA_GATEWAY_API=true`
> - Remove `PILOT_IGNORE_RESOURCES=""`
> - Delete the `istiod-enable-listenerset` Kyverno policy
> - Remove `kyverno-listenerset.yaml` from `okd/gateway/base/kustomization.yaml`

## Directory Structure

```plaintext
okd/gateway/
├── base/                          # Base manifests
│   ├── kustomization.yaml
│   └── kyverno-listenerset.yaml   # Istio pilot override (TEMPORARY)
├── components/
│   └── gateway/
│       ├── internal/              # Internal gateway + cert
│       └── external/              # External gateway + cert
└── overlays/okd/                  # OKD overlay
```
