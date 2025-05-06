# Stackrox Central

```bash
kubectl create ns stackrox

# Host Cluster
export ADMIN_PASSWORD="$(vault kv get --field=admin-password secret/homelab/stackrox/common)"

helm template -n stackrox --include-crds --create-namespace stackrox-central-services stackrox/stackrox-central-services \
 --set imagePullSecrets.allowNone=true --set central.exposure.route.enabled=true --set env.openshift=4 \
 --set central.adminPassword.value="${ADMIN_PASSWORD}" --set image.registry="quay.io/stackrox-io" \
 --set central.db.external=true --set central.db.password.value="<path:secret/data/homelab/stackrox/db#password>" \
 --set central.persistence.none=true \
 --set central.db.source.connectionString="host=stackrox-primary.postgres.svc port=5432 dbname=stackrox user=stackrox" \
   >central.yaml

kubectl -n stackrox exec deploy/central -- roxctl --insecure-skip-tls-verify \
 --password "${ADMIN_PASSWORD}" \
 central init-bundles generate stackrox-init-bundle --output - >stackrox-init-bundle.yaml

kubectl kustomize kubernetes/stackrox-central/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
