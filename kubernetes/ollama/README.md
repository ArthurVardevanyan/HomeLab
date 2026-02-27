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
- `pdb.yaml` - Pod disruption budget
- `rbac.yaml` - Role-based access control

## Usage

To deploy Ollama to OKD:

```bash
kubectl apply -k kubernetes/ollama/overlays/okd
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
