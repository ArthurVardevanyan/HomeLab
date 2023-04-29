# Stackrox Secure

```bash
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

 kubectl kustomize kubernetes/stackrox-secure/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
