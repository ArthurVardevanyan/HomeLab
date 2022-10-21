# Stackrox

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

# Target Cluster
export CLUSTER="homelab"
#   --set env.openshift=k8s

helm template -n stackrox stackrox-secured-cluster-services stackrox/stackrox-secured-cluster-services \
 -f stackrox-init-bundle.yaml \
 --set clusterName="${CLUSTER}" \
 --set sensor.resources.requests.memory=125Mi \
 --set sensor.resources.requests.cpu=125m \
 --set sensor.resources.limits.memory=500Mi \
 --set sensor.resources.limits.cpu=500m   --set env.openshift=4  >secure.yaml

```
