# Gitea

```bash
kubectl kustomize kubernetes/gitea/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -

helm template gitea gitea-charts/gitea -f values.yaml --namespace=gitea > temp.yaml
```
