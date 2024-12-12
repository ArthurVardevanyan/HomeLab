# External Secrets Operator

```bash
kubectl kustomize kubernetes/external-secrets-operator/overlays/okd | kubectl apply -f -
```

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm template external-secrets external-secrets/external-secrets --include-crds --namespace external-secrets-operator  -f values.yaml
```

## REF

- <https://external-secrets.io/latest/provider/hashicorp-vault/#kubernetes-authentication>
