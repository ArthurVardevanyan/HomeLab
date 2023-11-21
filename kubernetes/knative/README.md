# Knative

```bash
kubectl kustomize kubernetes/knative/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
