# CockroachDB

```bash
kubectl kustomize kubernetes/cockroachdb/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
