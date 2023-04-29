# Kube Eagle

```bash
kubectl kustomize kubernetes/kube-eagle/overlays/default | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://grafana.com/grafana/dashboards/9871>
- <https://github.com/cloudworkz/kube-eagle>
