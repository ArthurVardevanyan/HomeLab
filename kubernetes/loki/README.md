# Loki

```bash
kubectl kustomize kubernetes/loki/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/grafana/loki/issues/6121>
