# Uptime Kuma

```bash
kubectl kustomize kubernetes/uptime-kuma/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/louislam/uptime-kuma/tree/k8s-unofficial/kubernetes>
