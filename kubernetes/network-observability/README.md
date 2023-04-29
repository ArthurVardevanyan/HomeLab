# Netobserv

```bash
kubectl kustomize kubernetes/network-observability/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/netobserv/documents/blob/main/loki_distributed.md>
- <https://min.io/docs/minio/linux/operations/install-deploy-manage/migrate-fs-gateway.html>
- <https://access.redhat.com/documentation/en-us/openshift_container_platform/4.12/html/networking/network-observability>
