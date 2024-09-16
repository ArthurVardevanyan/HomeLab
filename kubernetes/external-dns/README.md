# External DNS

```bash
kubectl kustomize kubernetes/external-dns/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -

helm template external-dns external-dns/external-dns --version 1.15.0 --include-crds > temp.yaml


helm template gitea gitea-charts/gitea -f values.yaml --namespace=gitea
```