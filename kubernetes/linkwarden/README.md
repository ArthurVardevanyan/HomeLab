# Linkwarden

```bash
kubectl kustomize kubernetes/linkwarden/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/linkwarden/linkwarden>
