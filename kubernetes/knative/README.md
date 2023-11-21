# Knative

```bash
kubectl create namespace knative-serving --dry-run=client  -o yaml | kubectl apply -f -
kubectl kustomize kubernetes/knative/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
