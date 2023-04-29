# Kubernetes Dashboard

```bash
kubectl kustomize kubernetes/kubernetes-dashboard/overlays/k3s | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard/>
- <https://dashboard.arthurvardevanyan.com/#/pod?namespace=database>
