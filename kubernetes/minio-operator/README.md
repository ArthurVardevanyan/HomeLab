# Minio

```bash
kubectl kustomize kubernetes/minio/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/minio/operator/blob/master/README.md>
- <https://min.io/docs/minio/linux/operations/install-deploy-manage/migrate-fs-gateway.html>
