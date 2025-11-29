# External DNS

```bash
kubectl kustomize kubernetes/external-dns/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -

helm template external-dns external-dns/external-dns --version 1.20.0 --include-crds > /tmp/dump.yaml
```
