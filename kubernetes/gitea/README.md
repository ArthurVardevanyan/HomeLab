# Gitea

```bash
kubectl kustomize kubernetes/gitea/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
