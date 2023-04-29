# Version Checker

```bash
kubectl kustomize kubernetes/version-checker/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/jetstack/version-checker>
