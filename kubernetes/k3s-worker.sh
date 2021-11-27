#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

K3S_TOKEN=<K3S_TOKEN>
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=enp6s0" K3S_URL=https://10.0.0.3:6443 K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_CHANNEL=latest sh -

# kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data && kubectl delete node k3s-worker && sudo shutdown
