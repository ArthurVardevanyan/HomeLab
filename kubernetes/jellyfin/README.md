# Jellyfin

```bash
kubectl kustomize kubernetes/jellyfin/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
