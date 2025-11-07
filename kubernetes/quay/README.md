# Quay

```bash
kubectl kustomize kubernetes/quay/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## ShutDown

```bash
  kubectl scale --replicas=0 -n quay deployment/quay-operator-tng
  kubectl scale --replicas=0 -n quay deployment/quay-quay-app
  kubectl scale --replicas=0 -n quay deployment/quay-clair-app
  kubectl scale --replicas=0 -n quay deployment/quay-quay-mirror
```

## REF

- <https://access.redhat.com/documentation/en-us/red_hat_quay/3/html/deploy_red_hat_quay_on_openshift_with_the_quay_operator/operator-config-cli>
- <https://idbs-engineering.com/containers/2019/08/27/auto-expiry-quayio-tags.html>
- <https://docs.projectquay.io/deploy_quay_on_openshift_op_tng.html>
- <https://access.redhat.com/documentation/en-us/red_hat_quay/3.7/html/manage_red_hat_quay/clair-intro2>
