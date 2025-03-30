# Kubernetes Dashboard

```bash
kubectl kustomize kubernetes/kubernetes-dashboard/overlays/k3s | argocd-vault-plugin generate - | kubectl apply -f -
```

```bash
# https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard

kubectl get secret -n kubernetes-dashboard admin-user-token -o jsonpath="{.data.token}" | base64 --decode
```

## REF

- <https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard/>
- <https://dashboard.arthurvardevanyan.com/#/pod?namespace=database>
