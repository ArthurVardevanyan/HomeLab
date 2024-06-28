# Knative

```bash
kubectl kustomize kubernetes/kubevirt/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
