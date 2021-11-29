#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

BLUE='\033[1;34m'
NC='\033[0m'

echo -e " \n \n${BLUE}Kube System:${NC}"
kubectl patch deployment -n kube-system metrics-server --patch "$(cat kubernetes/kube-system/metrics-server-deployment.yaml)"
kubectl apply -f kubernetes/kube-system/kube-system-limitRange.yaml
kubectl apply -f kubernetes/kube-system/kube-system-resourceQuota.yaml

echo -e " \n${BLUE}Longhorn:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/longhorn/longhorn-traefik.yaml
kubectl apply -f kubernetes/longhorn

echo -e " \n${BLUE}Kube Eagle:${NC}"
kubectl apply -f kubernetes/kube-eagle

echo -e " \n${BLUE}Kubernetes Dashboard:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/kubernetes-dashboard/kubernetes-dashboard-traefik.yaml
kubectl apply -f kubernetes/kubernetes-dashboard

echo -e " \n${BLUE}Certificate Manager:${NC}"
sh kubernetes/cert-manager/cert-manager-deployment.sh
sed -i "s/<URL>/${URL}/g" kubernetes/cert-manager/cert-manager-cloudflare.yaml
sed -i "s,<CLOUDFLARE_EMAIL>,${CLOUDFLARE_EMAIL},g" kubernetes/cert-manager/cert-manager-cloudflare.yaml
sed -i "s,<CLOUDFLARE_API>,${CLOUDFLARE_API},g" kubernetes/cert-manager/cert-manager-cloudflare-secret.yaml
kubectl apply -f kubernetes/cert-manager

echo -e " \n${BLUE}Image Version Checker:${NC}"
kubectl apply -f kubernetes/version-checker

echo -e " \n${BLUE}Traefik:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/traefik/traefik-dashboard-traefik.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/traefik/cluster-wildcard-certificate.yaml
kubectl apply -f kubernetes/traefik

echo -e " \n${BLUE}Heimdall:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/heimdall/heimdall-traefik.yaml
kubectl apply -f kubernetes/heimdall

echo -e " \n${BLUE}influxdb:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/influxdb/influxdb-traefik.yaml
kubectl apply -f kubernetes/influxdb

echo -e " \n${BLUE}prometheus:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/prometheus/prometheus-traefik.yaml
kubectl apply -f kubernetes/prometheus

echo -e " \n${BLUE}Grafana:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/grafana/grafana-traefik.yaml
kubectl apply -f kubernetes/grafana

echo -e " \n${BLUE}Nextcloud:${NC}"
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/nextcloud/nextcloud-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/nextcloud/nextcloud-cert.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/nextcloud/nextcloud-traefik.yaml
kubectl apply -f kubernetes/nextcloud

echo -e " \n${BLUE}Mariadb:${NC}"
sed -i "s,<PASSWORD>,${SUDO},g" kubernetes/mariadb/mariadb-env-configmap.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/mariadb/mariadb-traefik.yaml
kubectl apply -f kubernetes/mariadb

echo -e " \n${BLUE}phpMyAdmin:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/phpmyadmin/phpmyadmin-traefik.yaml
kubectl apply -f kubernetes/phpmyadmin

echo -e " \n${BLUE}Home Assistant:${NC}"
kubectl apply -f kubernetes/homeassistant

echo -e " \n${BLUE}Vault:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/vault/vault-traefik.yaml
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/vault/vault-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/vault/vault-cert.yaml
kubectl apply -f kubernetes/vault

echo -e " \n${BLUE}Gitlab Runner:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-runner/gitlab-runner-config-map.yaml
sed -i "s/<GITLAB_RUNNER_TOKEN>/${GITLAB_RUNNER_TOKEN}/g" kubernetes/gitlab/gitlab-runner/gitlab-runner-config-map.yaml
kubectl apply -f kubernetes/gitlab/gitlab-runner/

echo -e " \n${BLUE}Gitlab:${NC}"
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<GENERIC_CERT>/${GENERIC_CERT}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<GENERIC_KEY>/${GENERIC_KEY}/g" kubernetes/gitlab/gitlab-cert.yaml
sed -i "s/<HEALTH_CHECK_TOKEN>/${HEALTH_CHECK_TOKEN}/g" kubernetes/gitlab/gitlab-deployment.yaml
sed -i "s/<URL>/${URL}/g" kubernetes/gitlab/gitlab-traefik.yaml
kubectl apply -f kubernetes/gitlab
