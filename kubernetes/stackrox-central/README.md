# Stackrox Central

```bash
kubectl create ns stackrox

# Host Cluster
export ADMIN_PASSWORD="$(vault kv get --field=admin-password secret/homelab/stackrox/common)"

helm template -n stackrox --create-namespace stackrox-central-services stackrox/stackrox-central-services \
 --set imagePullSecrets.allowNone=true --set central.exposure.route.enabled=true --set env.openshift=4 \
 --set central.adminPassword.value="${ADMIN_PASSWORD}" --set image.registry="quay.io/stackrox-io" >central.yaml

kubectl -n stackrox exec deploy/central -- roxctl --insecure-skip-tls-verify \
 --password "${ADMIN_PASSWORD}" \
 central init-bundles generate stackrox-init-bundle --output - >stackrox-init-bundle.yaml
```
