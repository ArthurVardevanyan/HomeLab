curl --insecure --header "Authorization: Bearer $(kubectl create token -n kubernetes-dashboard admin-user)" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/healthz

curl --insecure --header "Authorization: Bearer $(kubectl create token -n kubernetes-dashboard admin-user)" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/.well-known/openid-configuration

curl --insecure --header "Authorization: Bearer $(kubectl create token -n kubernetes-dashboard admin-user)" -H 'Content-type: application/json' \
	https://10.0.0.5:6443/openid/v1/jwks

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init --disable traefik \
	--kubelet-arg system-reserved=cpu=50m,memory=256Mi \
	--kubelet-arg kube-reserved=cpu=150m,memory=512Mi \
	--kube-apiserver-arg feature-gates=ServiceAccountIssuerDiscovery=true \
	--kube-apiserver-arg service-account-issuer=https://storage.googleapis.com/k3s-homelab-wif-oidc \
	--kube-apiserver-arg service-account-jwks-uri=https://storage.googleapis.com/k3s-homelab-wif-oidc/keys.json" \
	INSTALL_K3S_CHANNEL=latest sh -
