# Bitwarden (Vaultwarden)

```bash
kubectl kustomize kubernetes/bitwarden/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/dani-garcia/vaultwarden/wiki>
