#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export K3S_TOKEN=<K3S_TOKEN>
# Server
#curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --flannel-iface=enp1s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=500m,memory=1Gi" INSTALL_K3S_CHANNEL=v1.22 sh -

# Infra
#curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=enp1s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi" K3S_URL=https://10.0.0.5:6443 K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_CHANNEL=v1.22 sh -

# Worker
#curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=enp6s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi" K3S_URL=https://10.0.0.5:6443 K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_CHANNEL=v1.22 sh -

# kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data && kubectl delete node k3s-worker && sudo shutdown
