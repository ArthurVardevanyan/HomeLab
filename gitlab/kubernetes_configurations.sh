#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

BLUE='\033[1;34m'
NC='\033[0m'

echo -e " \n \n${BLUE}Load Secrets From Vault:${NC}"
URL=${URL:-$(vault kv get -field=url secret/gitlab/domain)}
CLOUDFLARE_EMAIL=$(vault kv get -field=email secret/gitlab/cloudflare)
CLOUDFLARE_API=$(vault kv get -field=api secret/gitlab/cloudflare)
GENERIC_CERT=$(vault kv get -field=generic_cert secret/gitlab/cert)
GENERIC_KEY=$(vault kv get -field=generic_key secret/gitlab/cert)
MARIADB_PASSWORD=$(vault kv get -field=password secret/gitlab/mariadb)
PHOTOPRISM_DB_PASSWORD=$(vault kv get -field=db_password secret/gitlab/photoprism)
PHOTOPRISM_ADMIN_PASSWORD=$(vault kv get -field=admin_password secret/gitlab/photoprism)
GITLAB_RUNNER_TOKEN=$(vault kv get -field=token secret/gitlab/runner)
HEALTH_CHECK_TOKEN=$(vault kv get -field=token secret/gitlab/health)
echo "Secrets Loaded"

echo -e " \n \n${BLUE}Kube System:${NC}"
kubectl apply -f kubernetes/kube-system/kube-system-limitRange.yaml
kubectl apply -f kubernetes/kube-system/kube-system-resourceQuota.yaml
kubectl patch deployment -n kube-system metrics-server --patch "$(cat kubernetes/kube-system/kube-deployments.yaml)"
kubectl patch deployment -n kube-system coredns --patch "$(cat kubernetes/kube-system/kube-deployments.yaml)"
kubectl patch deployment -n kube-system local-path-provisioner --patch "$(cat kubernetes/kube-system/kube-deployments.yaml)"

echo -e " \n${BLUE}Certificate Manager:${NC}"
kubectl kustomize kubernetes/cert-manager/base | kubectl apply -f -
sh kubernetes/cert-manager/components/yaml/crds.sh
sed -i "s/<URL>/${URL}/g" kubernetes/cert-manager/components/cloudflare/cluster-issuer.yaml
sed -i "s,<CLOUDFLARE_EMAIL>,${CLOUDFLARE_EMAIL},g" kubernetes/cert-manager/components/cloudflare/cluster-issuer.yaml
sed -i "s,<CLOUDFLARE_API>,${CLOUDFLARE_API},g" kubernetes/cert-manager/components/cloudflare/api-token.yaml
kubectl kustomize kubernetes/cert-manager/overlays/k8s | kubectl apply -f -

echo -e " \n${BLUE}Traefik:${NC}"
kubectl apply -f kubernetes/traefik/traefik-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/traefik/traefik-dashboard-traefik.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/traefik/cluster-wildcard-certificate.yaml
kubectl apply -f kubernetes/traefik/traefik-crd.yaml
kubectl apply -f kubernetes/traefik

echo -e " \n${BLUE}Longhorn:${NC}"
kubectl apply -f kubernetes/longhorn/longhorn-namespace.yaml
kubectl apply -f kubernetes/longhorn/nodes
sed -i "s/<URL>/${URL}/g" kubernetes/longhorn/longhorn-traefik.yaml
kubectl apply -f kubernetes/longhorn
echo -e "\n${BLUE}Waiting for Longhorn to Boot:${NC}"
while [ "$(kubectl get pods -n longhorn-system | egrep -v "Running|Completed" | wc -l)" -ne 1 ]; do
	sleep 1
done
kubectl patch daemonset -n longhorn-system longhorn-csi-plugin --patch "$(cat kubernetes/longhorn/patches/longhorn-csi-plugin.yaml)"
kubectl patch deployment -n longhorn-system csi-resizer --patch "$(cat kubernetes/longhorn/patches/csi-resizer.yaml)"
kubectl patch deployment -n longhorn-system csi-snapshotter --patch "$(cat kubernetes/longhorn/patches/csi-snapshotter.yaml)"
kubectl patch deployment -n longhorn-system csi-attacher --patch "$(cat kubernetes/longhorn/patches/csi-attacher.yaml)"
kubectl patch deployment -n longhorn-system csi-provisioner --patch "$(cat kubernetes/longhorn/patches/csi-provisioner.yaml)"
kubectl apply -f kubernetes/longhorn/backup

echo -e " \n${BLUE}Kube Eagle:${NC}"
kubectl apply -f kubernetes/kube-eagle

echo -e " \n${BLUE}Kubernetes Dashboard:${NC}"
kubectl apply -f kubernetes/kubernetes-dashboard/kubernetes-dashboard-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/kubernetes-dashboard/kubernetes-dashboard-traefik.yaml
kubectl apply -f kubernetes/kubernetes-dashboard

echo -e " \n${BLUE}Image Version Checker:${NC}"
kubectl apply -f kubernetes/version-checker/version-checker-namespace.yaml
kubectl apply -f kubernetes/version-checker

echo -e " \n${BLUE}Heimdall:${NC}"
kubectl apply -f kubernetes/heimdall/heimdall-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/heimdall/heimdall-traefik.yaml
kubectl apply -f kubernetes/heimdall

echo -e " \n${BLUE}Influxdb:${NC}"
kubectl apply -f kubernetes/influxdb/influxdb-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/influxdb/influxdb-traefik.yaml
kubectl apply -f kubernetes/influxdb

echo -e " \n${BLUE}Prometheus:${NC}"
kubectl apply -f kubernetes/prometheus/prometheus-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/prometheus/prometheus-traefik.yaml
kubectl apply -f kubernetes/prometheus

echo -e " \n${BLUE}Grafana:${NC}"
kubectl apply -f kubernetes/grafana/grafana-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/grafana/grafana-traefik.yaml
kubectl apply -f kubernetes/grafana

echo -e " \n${BLUE}Grafana Loki:${NC}"
kubectl apply -f kubernetes/grafana-loki

echo -e " \n${BLUE}Grafana Promtail:${NC}"
kubectl apply -f kubernetes/grafana-promtail

echo -e " \n${BLUE}Nextcloud:${NC}"
kubectl apply -f kubernetes/nextcloud/nextcloud-namespace.yaml
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/nextcloud/nextcloud-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/nextcloud/nextcloud-cert.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/nextcloud/nextcloud-traefik.yaml
kubectl apply -f kubernetes/nextcloud

echo -e " \n${BLUE}Mariadb:${NC}"
kubectl apply -f kubernetes/mariadb/database-namespace.yaml
sed -i "s,<PASSWORD>,${MARIADB_PASSWORD},g" kubernetes/mariadb/mariadb-env-configmap.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/mariadb/mariadb-traefik.yaml
kubectl apply -f kubernetes/mariadb
kubectl apply -f kubernetes/mariadb/mysqldump

echo -e " \n${BLUE}phpMyAdmin:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/phpmyadmin/phpmyadmin-traefik.yaml
kubectl apply -f kubernetes/phpmyadmin

echo -e " \n${BLUE}Home Assistant:${NC}"
kubectl apply -f kubernetes/homeassistant/homeassistant-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/homeassistant/homeassistant-traefik.yaml
kubectl apply -f kubernetes/homeassistant

echo -e " \n${BLUE}Vault:${NC}"
kubectl apply -f kubernetes/vault/vault-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/vault/vault-traefik.yaml
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/vault/vault-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/vault/vault-cert.yaml
kubectl apply -f kubernetes/vault

echo -e " \n${BLUE}Bitwarden:${NC}"
kubectl apply -f kubernetes/bitwarden/bitwarden-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/bitwarden/bitwarden-traefik.yaml
kubectl apply -f kubernetes/bitwarden

echo -e " \n${BLUE}Uptime Kuma:${NC}"
kubectl apply -f kubernetes/uptime-kuma/uptime-kuma-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/uptime-kuma/uptime-kuma-traefik.yaml
kubectl apply -f kubernetes/uptime-kuma

echo -e " \n${BLUE}Photoprism:${NC}"
kubectl apply -f kubernetes/photoprism/photoprism-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/photoprism/photoprism-traefik.yaml
sed -i "s/<PHOTOPRISM_DB_PASSWORD>/${PHOTOPRISM_DB_PASSWORD}/g" kubernetes/photoprism/photoprism-secret.yaml
sed -i "s/<PHOTOPRISM_ADMIN_PASSWORD>/${PHOTOPRISM_ADMIN_PASSWORD}/g" kubernetes/photoprism/photoprism-secret.yaml
kubectl apply -f kubernetes/photoprism

echo -e " \n${BLUE}JellyFin:${NC}"
kubectl apply -f kubernetes/jellyfin/jellyfin-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/jellyfin/jellyfin-traefik.yaml
kubectl apply -f kubernetes/jellyfin

echo -e " \n${BLUE}Gitlab Runner:${NC}"
kubectl apply -f kubernetes/gitlab/gitlab-runner/gitlab-runner-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-runner/gitlab-runner-config-map.yaml
sed -i "s/<GITLAB_RUNNER_TOKEN>/${GITLAB_RUNNER_TOKEN}/g" kubernetes/gitlab/gitlab-runner/gitlab-runner-config-map.yaml
kubectl apply -f kubernetes/gitlab/gitlab-runner/

echo -e " \n${BLUE}Gitlab:${NC}"
kubectl apply -f kubernetes/gitlab/gitlab-namespace.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<HEALTH_CHECK_TOKEN>/${HEALTH_CHECK_TOKEN}/g" kubernetes/gitlab/gitlab-statefulSet.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-traefik.yaml
kubectl apply -f kubernetes/gitlab
