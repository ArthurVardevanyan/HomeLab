# External Secrets Operator

```bash
kubectl kustomize kubernetes/external-secrets-operator/overlays/okd | kubectl apply -f -
```

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm template external-secrets external-secrets/external-secrets --include-crds --namespace external-secrets-operator  -f kubernetes/external-secrets-operator/values.yaml

kubectl kustomize https://github.com/external-secrets/external-secrets.git/config/crds/bases/?ref=v0.19.2  > kubernetes/external-secrets-operator/components/helm/crd.yaml
```

## REF

- <https://external-secrets.io/latest/provider/hashicorp-vault/#kubernetes-authentication>
