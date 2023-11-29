# Container Security Operator

```bash
kubectl kustomize kubernetes/container-security/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/ArthurVardevanyan/container-security-operator>
