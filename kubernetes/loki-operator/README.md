# Loki Operator

```bash
kubectl kustomize kubernetes/loki-operator/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
