#!/bin/bash

# Server 1
ssh fedora@10.0.0.140
sudo su
export K3S_TOKEN=SECRET
curl -sfL https://get.k3s.io | sh -s - server \
	--cluster-init \
	--node-ip 10.0.0.140 --tls-san=10.0.0.134

# Get Creds for Next 2 Hosts
cat /etc/rancher/k3s/k3s.yaml
cat /var/lib/rancher/k3s/server/token

# Server 2
ssh fedora@10.0.0.141
sudo su
export K3S_TOKEN=SECRET
curl -sfL https://get.k3s.io | sh -s - server \
	--server https://10.0.0.134:6443 \
	--node-ip 10.0.0.141 --tls-san=10.0.0.134

# Server 3
sudo su
ssh fedora@10.0.0.142
export K3S_TOKEN=SECRET
curl -sfL https://get.k3s.io | sh -s - server \
	--server https://10.0.0.134:6443 \
	--node-ip 10.0.0.142 --tls-san=10.0.0.134
