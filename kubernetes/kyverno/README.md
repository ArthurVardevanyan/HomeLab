# Kyverno

Only Admission Controller is Active

```bash
kubectl kustomize kubernetes/kyverno/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -

wget https://github.com/kyverno/kyverno/releases/download/v1.15.1/install.yaml
```

## REF

- <https://kyverno.io/docs/installation/methods>
