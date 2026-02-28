# Ollama Deployment

This directory contains the Kubernetes deployment configuration for Ollama using Kustomize overlays.

## Directory Structure

- `base/` - Base Kubernetes resources for Ollama
- `overlays/` - Environment-specific overlays
  - `okd/` - OKD-specific configuration

## Base Resources

The base directory contains the following resources:

- `namespace.yaml` - Ollama namespace
- `service-account.yaml` - Service account for Ollama
- `service.yaml` - ClusterIP service for Ollama
- `deployment.yaml` - Ollama deployment with GPU support
- `network-policy.yaml` - Network policies for Ollama

### Network Policies

The base deployment includes multiple network policies:

| Policy Name                  | Description                                                          |
| ---------------------------- | -------------------------------------------------------------------- |
| `deny-all`                   | Default deny both ingress and egress                                 |
| `allow-dns-traffic`          | Allows egress to OpenShift DNS (port 53)                             |
| `allow-ollama-api`           | Allows ingress on port 11434 from same namespace                     |
| `allow-openshift-monitoring` | Allows ingress on port 11434 from OpenShift monitoring namespaces    |
| `allow-external-egress`      | Allows egress to external networks (excludes RFC1918 private ranges) |

## OKD Overlay Resources

The `okd/` overlay adds:

- `egress-firewall.yaml` - OVN EgressFirewall for additional egress control (Cloudflare IPs for registry.ollama.ai)

## Usage

To deploy Ollama to OKD:

```bash
kubectl apply -k kubernetes/ollama/overlays/okd
```

To deploy to other Kubernetes clusters:

```bash
kubectl apply -k kubernetes/ollama/base
```

## Configuration

The deployment uses the official Ollama Docker image and exposes port 11434. It's configured with:

- GPU support (nvidia.com/gpu resource)
- Persistent storage for Ollama configuration
- Pre-pulled models (qwen2.5-coder:1.5b, qwen3-coder:30b, nomic-embed-text)
- GPU node toleration
- Runtime class for GPU scheduling
- Resource limits: 10 CPU, 48Gi memory, 1 GPU
- Resource requests: 8 CPU, 48Gi memory
