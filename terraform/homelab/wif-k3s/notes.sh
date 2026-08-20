#!/bin/bash

DASHBOARD_TOKEN=$(kubectl create token -n kubernetes-dashboard admin-user) || { echo "Error: Failed to create dashboard token" >&2; exit 1; }

curl -sf --insecure --header "Authorization: Bearer ${DASHBOARD_TOKEN}" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/healthz || { echo "Warning: endpoint unreachable" >&2; }

curl -sf --insecure --header "Authorization: Bearer ${DASHBOARD_TOKEN}" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/.well-known/openid-configuration || { echo "Warning: endpoint unreachable" >&2; }

curl -sf --insecure --header "Authorization: Bearer ${DASHBOARD_TOKEN}" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/openid/v1/jwks || { echo "Warning: endpoint unreachable" >&2; }

SCRIPT=$(curl -fsSL https://get.k3s.io) || { echo "Error: failed to download k3s installer" >&2; exit 1; }
echo "${SCRIPT}" | INSTALL_K3S_EXEC="server --cluster-init --disable traefik \
	--kubelet-arg system-reserved=cpu=50m,memory=256Mi \
	--kubelet-arg kube-reserved=cpu=150m,memory=512Mi \
	--kube-apiserver-arg feature-gates=ServiceAccountIssuerDiscovery=true \
	--kube-apiserver-arg service-account-issuer=https://storage.googleapis.com/k3s-homelab-wif-oidc \
	--kube-apiserver-arg service-account-jwks-uri=https://storage.googleapis.com/k3s-homelab-wif-oidc/keys.json" \
	INSTALL_K3S_CHANNEL=latest sh - || { echo "Error: k3s install failed" >&2; exit 1; }
