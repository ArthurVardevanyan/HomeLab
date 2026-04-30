# Ollama

GPU-backed [Ollama](https://ollama.com) deployment serving local LLMs to the homelab.

```bash
kubectl kustomize kubernetes/ollama/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Models

Pulled via the container `postStart` lifecycle hook:

- `qwen3.6:35b-a3b`
- `gemma4:26b-a4b-it`

## Scaling

The deployment is scaled to `0` by default to free the GPU.
Scale up to load the models:

```bash
kubectl scale deployment/ollama-coder -n ollama --replicas=1
```

## Layout

- `base/` - Base resources (namespace, RBAC, network policies, PVC, services, deployment, VPA)
- `overlays/okd/` - OKD overlay adding the OVN `EgressFirewall` to permit only `registry.ollama.ai` egress (Cloudflare ranges)

### Network Policies

| Policy                       | Description                                         |
| ---------------------------- | --------------------------------------------------- |
| `deny-all`                   | Default deny ingress + egress                       |
| `allow-dns-traffic`          | Egress to OpenShift DNS                             |
| `allow-ollama-api`           | Ingress on `:11434` from same namespace             |
| `allow-openshift-monitoring` | Ingress on `:11434` from cluster + UWM Prometheus   |
| `allow-external-egress`      | Egress to public internet (excludes RFC1918 ranges) |

## REF

- <https://github.com/ollama/ollama>
- <https://hub.docker.com/r/ollama/ollama>
