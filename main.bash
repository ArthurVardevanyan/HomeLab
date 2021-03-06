#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# PRESEED CONFIG: /machineConfigs/servers/preseed.cfg
# ANSIBLE CONFIG: /ansible/k3s.yaml

BLUE='\033[1;34m'
NC='\033[0m'

# https://www.how2shout.com/linux/how-to-install-and-configure-kvm-on-debian-11-bullseye-linux/
export LIBVIRT_DEFAULT_URI=qemu:///system

# HomeLab Functions

ansible() {
	ansible-playbook -i ansible/inventory --ask-become-pass ansible/servers.yaml --ask-pass \
		-e 'ansible_python_interpreter=/usr/bin/python3'
}

stateful_workload_stop() {
	kubectl patch cronjobs -n photoprism photoprism-cron -p '{"spec" : {"suspend" : true }}'
	kubectl patch cronjobs -n nextcloud nextcloud-preview -p '{"spec" : {"suspend" : true }}'
	kubectl patch cronjobs -n nextcloud nextcloud-rsync -p '{"spec" : {"suspend" : true }}'
	kubectl patch cronjobs -n nextcloud nextcloud-cron -p '{"spec" : {"suspend" : true }}'
	kubectl patch cronjobs -n mariadb-galera mysqldump-cron -p '{"spec" : {"suspend" : true }}'

	kubectl delete configmap -n openshift-monitoring cluster-monitoring-config --ignore-not-found

	kubectl patch -n bitwarden statefulset/bitwarden --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n gitea statefulset/gitea --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n grafana deployment/grafana --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n heimdall statefulset/heimdall --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n homeassistant statefulset/homeassistant --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n influxdb statefulset/influxdb --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n loki statefulset/loki --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n mariadb-galera statefulset/mariadb-galera --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n nextcloud statefulset/nextcloud --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n photoprism statefulset/photoprism --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n prometheus statefulset/prometheus --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n uptime-kuma statefulset/uptime-kuma --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'
	kubectl patch -n vault statefulset/vault --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 0}]'

	kubectl scale --replicas=0 -n minio deployment/minio
	kubectl scale --replicas=0 -n quay deployment/quay-quay-app
	kubectl scale --replicas=0 -n quay deployment/quay-clair-app
	kubectl scale --replicas=0 -n gitea statefulset/gitea
	kubectl scale --replicas=0 -n postgres deployment/pgo
	kubectl scale --replicas=0 -n postgres statefulset clair-00-6rrz
	kubectl scale --replicas=0 -n postgres statefulset/clair-repo-host
	kubectl scale --replicas=0 -n postgres statefulset/quay-00-87fl
	kubectl scale --replicas=0 -n postgres statefulset/quay-repo-host

	kubectl scale --replicas=0 -n argocd deployment/argocd-operator-controller-manager
	kubectl scale --replicas=0 -n argocd statefulset/argocd-application-controller
	kubectl scale --replicas=0 -n argocd deployment/argocd-repo-server
	kubectl scale --replicas=0 -n argocd deployment/argocd-dex-server
	kubectl scale --replicas=0 -n argocd deployment/argocd-server
	kubectl scale --replicas=0 -n argocd deployment/argocd-redis

}

stateful_workload_start() {
	kubectl patch cronjobs -n photoprism photoprism-cron -p '{"spec" : {"suspend" : false }}'
	kubectl patch cronjobs -n nextcloud nextcloud-preview -p '{"spec" : {"suspend" : false }}'
	kubectl patch cronjobs -n nextcloud nextcloud-rsync -p '{"spec" : {"suspend" : false }}'
	kubectl patch cronjobs -n nextcloud nextcloud-cron -p '{"spec" : {"suspend" : false }}'
	kubectl patch cronjobs -n mariadb-galera mysqldump-cron -p '{"spec" : {"suspend" : false }}'

	kubectl apply -f okd/openshift-monitoring/base/cluster-monitoring-config.yaml

	kubectl patch -n bitwarden statefulset/bitwarden --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n gitea statefulset/gitea --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n grafana deployment/grafana --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n heimdall statefulset/heimdall --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n homeassistant statefulset/homeassistant --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n influxdb statefulset/influxdb --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n loki statefulset/loki --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n mariadb-galera statefulset/mariadb-galera --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 3}]'
	kubectl patch -n nextcloud statefulset/nextcloud --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n photoprism statefulset/photoprism --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n prometheus statefulset/prometheus --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n uptime-kuma statefulset/uptime-kuma --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'
	kubectl patch -n vault statefulset/vault --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value": 1}]'

	kubectl scale --replicas=1 -n minio deployment/minio
	kubectl scale --replicas=1 -n quay deployment/quay-quay-app
	kubectl scale --replicas=1 -n quay deployment/quay-clair-app
	kubectl scale --replicas=1 -n gitea statefulset/gitea
	kubectl scale --replicas=1 -n postgres deployment/pgo
	kubectl scale --replicas=1 -n postgres statefulset clair-00-6rrz
	kubectl scale --replicas=1 -n postgres statefulset/clair-repo-host
	kubectl scale --replicas=1 -n postgres statefulset/quay-00-87fl
	kubectl scale --replicas=1 -n postgres statefulset/quay-repo-host

	kubectl scale --replicas=1 -n argocd deployment/argocd-operator-controller-manager
	kubectl scale --replicas=1 -n argocd statefulset/argocd-application-controller
	kubectl scale --replicas=1 -n argocd deployment/argocd-repo-server
	kubectl scale --replicas=1 -n argocd deployment/argocd-dex-server
	kubectl scale --replicas=1 -n argocd deployment/argocd-server
	kubectl scale --replicas=1 -n argocd deployment/argocd-redis

	echo -e "\nkubectl exec -it vault-0 -n vault -- vault operator unseal --tls-skip-verify"
}

kvm-infra() {
	ssh 10.0.0.110

	virt-install \
		--noautoconsole \
		--graphics vnc \
		--name=k3s-server-2 \
		--os-variant=debian10 \
		--vcpus sockets=1,cores=1,threads=2 \
		--ram=1792 \
		--disk "${HOME}/vm/k3s-server-2".img,,format=raw,size=25 \
		--network bridge=br0,mac="10:00:00:00:01:02" \
		--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
		--extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-server-2 \
            url=http://10.0.0.5:7071/preseed.cfg"

	virt-install \
		--noautoconsole \
		--graphics vnc \
		--name=k3s-worker-1 \
		--os-variant=debian10 \
		--vcpus sockets=1,cores=2,threads=2 \
		--ram=10240 \
		--disk "${HOME}/vm/k3s-worker-1".img,,format=raw,size=125 \
		--network bridge=br0,mac="10:00:00:00:01:11" \
		--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
		--extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-worker-1 \
            url=http://10.0.0.5:7071/preseed.cfg"

}

kvm() {
	ssh 10.0.0.3

	export LIBVIRT_DEFAULT_URI=qemu:///system

	virt-install \
		--noautoconsole \
		--graphics vnc \
		--name=k3s-server-3 \
		--os-variant=debian10 \
		--vcpus sockets=1,cores=1,threads=2 \
		--ram=1792 \
		--disk "${HOME}/vm/k3s-server-3".img,,format=raw,size=25 \
		--network bridge=br0,mac="10:00:00:00:01:03" \
		--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
		--extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-server-3 \
            url=http://10.0.0.5:7071/preseed.cfg"

	virt-install \
		--noautoconsole \
		--graphics vnc \
		--name=k3s-worker-2 \
		--os-variant=debian10 \
		--vcpus sockets=1,cores=2,threads=2 \
		--ram=4352 \
		--disk "${HOME}/vm/k3s-worker-2".img,,format=raw,size=125 \
		--network bridge=br0,mac="10:00:00:00:01:12" \
		--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
		--extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-worker-2 \
            url=http://10.0.0.5:7071/preseed.cfg"
}

label_nodes() {
	# Taint
	kubectl taint node k3s-server-1 node-role.kubernetes.io/master:NoSchedule --overwrite
	kubectl taint node k3s-server-2 node-role.kubernetes.io/master:NoSchedule --overwrite
	kubectl taint node k3s-server-3 node-role.kubernetes.io/master:NoSchedule --overwrite
	kubectl taint node k3s-server-2 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
	kubectl taint node k3s-server-3 node-role.kubernetes.io/control-plane:NoSchedule --overwrite

	# Role Label
	kubectl label node k3s-worker-1 node-role.kubernetes.io/infra=true --overwrite
	kubectl label node k3s-worker-1 node-role.kubernetes.io/worker=true --overwrite
	kubectl label node k3s-worker-2 node-role.kubernetes.io/worker=true --overwrite

	# Zone Labels
	kubectl label node k3s-server-1 topology.kubernetes.io/zone=bare-metal --overwrite
	kubectl label node k3s-server-2 topology.kubernetes.io/zone=infra-kvm --overwrite
	kubectl label node k3s-server-3 topology.kubernetes.io/zone=kvm --overwrite
	kubectl label node k3s-worker-1 topology.kubernetes.io/zone=infra-kvm --overwrite
	kubectl label node k3s-worker-2 topology.kubernetes.io/zone=kvm --overwrite

	# Longhorn Label
	kubectl label node k3s-server-1 node.longhorn.io/create-default-disk=true --overwrite
	kubectl label node k3s-worker-1 node.longhorn.io/create-default-disk=true --overwrite
	kubectl label node k3s-worker-2 node.longhorn.io/create-default-disk=true --overwrite

	# #Drain DaemonSets Temporarily off a Node
	# kubectl taint node k3s-server- node-role.kubernetes.io/control-plane:NoExecute
	# kubectl taint node k3s-server- node-role.kubernetes.io/control-plane:NoExecute-
}

k3s_setup() {
	# Configure PFsense / HAProxy / DHCP / DNS

	# Servers
	ansible-playbook -i ansible/inventory --ask-become-pass ansible/servers.yaml --ask-pass
	# Reboot All Kubernetes Nodes && For KVM Nodes Update DHCP Server With New Mac Address

	# Install VMs
	bash kvm_k3s.bash kvm-infra
	bash kvm_k3s.bash kvm

	bash kvm_k3s.bash ansible
	# Reboot VMs

	# Install K3s
	# First Time Setup
	export K3S_TOKEN=""
	export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi"

	curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init  --tls-san 10.0.0.100 --tls-san k3s.<URL>.com ${RESERVED}" \
		INSTALL_K3S_CHANNEL=v1.23 sh -

	# Servers
	export K3S_TOKEN=""
	export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi"

	curl -sfL https://get.k3s.io |
		INSTALL_K3S_EXEC="server --server https://10.0.0.100:6443 --disable traefik ${RESERVED}" \
			K3S_URL=https://10.0.0.100:6443 INSTALL_K3S_CHANNEL=v1.23 sh -

	# Agents/Workers
	export K3S_TOKEN=""
	export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=250Mi --kubelet-arg kube-reserved=cpu=250m,memory=250Mi"

	curl -sfL https://get.k3s.io |
		INSTALL_K3S_EXEC="${RESERVED}" \
			K3S_URL=https://10.0.0.100:6443 INSTALL_K3S_CHANNEL=v1.23 sh -

	# Label Nodes
	bash kvm_k3s label_nodes
}

k3s_image_cleanup() {
	export IP_LIST="5 102 103 111 112"

	for IP in $(echo "$IP_LIST"); do
		ssh -t arthur@10.0.0."${IP}" "sudo k3s crictl rmi --prune"
	done
}

# Sandbox Functions

# SANDBOX HAPROXY: /machineConfigs/sandbox/var/etc/haproxy

# Setup DHCP Network
# virsh net-edit default
# <host mac='10:10:00:00:00:03' ip='10.10.10.3'/>
# <host mac='10:10:00:00:00:04' ip='10.10.10.4'/>
# <host mac='10:10:00:00:00:05' ip='10.10.10.5'/>
# <host mac='10:10:00:00:00:06' ip='10.10.10.6'/>
# <host mac='10:10:00:00:00:07' ip='10.10.10.7'/>
# <host mac='10:10:00:00:00:08' ip='10.10.10.8'/>
# <host mac='10:10:00:00:00:09' ip='10.10.10.9'/>
# virsh net-destroy default && virsh net-start default

export START_IP=11
export PASSWORD=${PASSWORD:-}

stop_cluster() {
	echo -e "\n${BLUE}Stopping Cluster:${NC}"
	for NODE in ${NODES}; do
		if virsh destroy "${PREFIX}${NODE}"; then
			echo "Shutting Down:${PREFIX}${NODE}"
		fi
	done

}

start_cluster() {
	echo -e "\n${BLUE}Starting Cluster:${NC}"
	for NODE in ${NODES}; do
		virsh start "${PREFIX}${NODE}"
		echo "Started ${PREFIX}${NODE}"
	done
}

reboot_cluster() {
	echo -e "\n${BLUE}Rebooting Cluster:${NC}"
	for NODE in ${NODES}; do
		virsh reboot "${PREFIX}${NODE}"
		echo "Started ${PREFIX}${NODE}"
	done

	IP=${START_IP}
	for NODE in ${NODES}; do
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 1
			if nc -z 10.10.10.${IP} 22; then
				echo "${PREFIX}${NODE} is up."
				finished=1
			fi
		done
		((IP++))
	done

}

delete_cluster() {
	stop_cluster
	echo -e "\n${BLUE}Deleting Cluster:${NC}"
	for NODE in ${NODES}; do
		echo "${NODE}"
		if virsh undefine "${PREFIX}${NODE}" --remove-all-storage; then
			echo "Deleting: ${PREFIX}${NODE}"
		fi
	done
}

ansible_sandbox() {
	echo -e "\n${BLUE}Running Ansible Playbooks:${NC}"
	if [ -z "${PASSWORD}" ]; then
		echo -n Password:
		read -r -s PASSWORD
		echo ""
	fi
	IP=${START_IP}
	# Create Ansible Inventory File
	echo "[servers]" >/tmp/inventory
	for NODE in ${NODES}; do
		echo "10.10.10.${IP}" >>/tmp/inventory
		((IP++))
	done
	# Run Playbooks On All Machines
	ansible-playbook -i /tmp/inventory ansible/servers.yaml --extra-vars \
		"ansible_become_pass=${PASSWORD} ansible_ssh_pass=${PASSWORD}"
}

label_vms() {
	load_kubeconfig

	echo -e "\n${BLUE}Labeling Nodes:${NC}"
	for NODE in ${NODES}; do

		if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
			kubectl label nodes "${PREFIX}${NODE}" node-type=master --overwrite
			kubectl taint node "${PREFIX}${NODE}" node-role.kubernetes.io/master:NoSchedule --overwrite
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			kubectl label node "${PREFIX}${NODE}" node-role.kubernetes.io/worker=true --overwrite
			ZONE="EVEN"
			if ((${NODE##*-} % 2)); then
				ZONE="ODD"
			fi
			kubectl label node "${PREFIX}${NODE}" topology.kubernetes.io/zone="${ZONE}" --overwrite
			kubectl label node "${PREFIX}${NODE}" node.longhorn.io/create-default-disk=true --overwrite
		fi
	done

}

load_kubeconfig() {
	echo -e "\n${BLUE}Loading KubeConfig:${NC}"
	export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml
}

uninstall_k3s() {
	echo -e "\n\n${BLUE}Uninstall k3s:${NC}"

	if [ -z "${PASSWORD}" ]; then
		echo -n Password:
		read -r -s PASSWORD
		echo ""
	fi

	IP=${START_IP}
	for NODE in ${NODES}; do

		echo "${PREFIX}${NODE}"
		if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
			sshpass -p "${PASSWORD}" ssh -t 10.10.10.${IP} "echo ${PASSWORD}	| sudo -S /usr/local/bin/k3s-uninstall.sh"
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			sshpass -p "${PASSWORD}" ssh -t 10.10.10.${IP} "echo ${PASSWORD}	| sudo -S /usr/local/bin/k3s-agent-uninstall.sh"
		fi
		((IP++))
	done
}

install_k3s() {
	# Install & Setup k3s
	echo -e "\n\n${BLUE}Install & Setup k3s:${NC}"

	if [ -z "${PASSWORD}" ]; then
		echo -n Password:
		read -r -s PASSWORD
		echo ""
	fi

	K3S="echo ${PASSWORD}	| sudo -S ls; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='"
	K3S_RESERVED="--kubelet-arg system-reserved=cpu=125m,memory=250Mi --kubelet-arg kube-reserved=cpu=125m,memory=250Mi'"
	K3S_CONFIG="K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_CHANNEL=v1.23 sh -"

	INSTALL="${K3S} server --cluster-init --disable traefik ${K3S_RESERVED} ${K3S_CONFIG}"
	SERVER=" ${K3S} server --server https://10.10.10.1:6443 --disable traefik ${K3S_RESERVED} ${K3S_CONFIG}"
	WORKER=" ${K3S} ${K3S_RESERVED} K3S_URL=https://10.10.10.1:6443 ${K3S_CONFIG}"

	IP=${START_IP}
	for NODE in ${NODES}; do
		KUBE=0
		if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
			if [ ${IP} -eq ${START_IP} ]; then
				CONFIG=${INSTALL}
				KUBE=1
			else
				CONFIG=${SERVER}
			fi
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			CONFIG=${WORKER}
		fi

		echo "${PREFIX}${NODE}"
		sshpass -p "${PASSWORD}" ssh -t 10.10.10.${IP} "${CONFIG}"

		if [ ${KUBE} -eq 1 ]; then
			CMD="echo ${PASSWORD} | sudo -S cp /etc/rancher/k3s/k3s.yaml /tmp; sudo chmod 777 /tmp/k3s.yaml"
			sshpass -p "${PASSWORD}" ssh -t 10.10.10.${START_IP} "${CMD}"
			sshpass -p "${PASSWORD}" scp 10.10.10.${START_IP}:/tmp/k3s.yaml "${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
			sed -i "s,127.0.0.1,10.10.10.1,g" "${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
		fi
		((IP++))
	done

	echo -e "\n\n${BLUE}Install Complete!${NC}"
	echo "export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
	echo "${PREFIX} k3s Install Complete!"

}

install_addons() {
	# Tweak Settings from Physical HomeLab
	load_kubeconfig

	echo -e "\n${BLUE}Installing Cluster Addons:${NC}"
	echo -e "\n\n${BLUE}Get URL:${NC}"
	URL=${URL:-}
	if [ -z "${URL}" ]; then
		echo -n URL:
		read -r -s URL
		echo ""
	fi
	echo "${URL}"

	rm -rf /tmp/kubernetes
	cp -r kubernetes /tmp/

	echo -e "\n${BLUE}Traefik:${NC}"
	kubectl apply -f /tmp/kubernetes/traefik/traefik-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/traefik/traefik-dashboard-traefik.yaml
	rm -f /tmp/kubernetes/traefik/cluster-wildcard-certificate.yaml
	kubectl apply -f /tmp/kubernetes/traefik/traefik-crd.yaml
	kubectl apply -f /tmp/kubernetes/traefik

	echo -e "\n${BLUE}Kube Eagle:${NC}"
	kubectl apply -f /tmp/kubernetes/kube-eagle

	echo -e "\n${BLUE}Kubernetes Dashboard:${NC}"
	kubectl apply -f /tmp/kubernetes/kubernetes-dashboard/kubernetes-dashboard-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/kubernetes-dashboard/kubernetes-dashboard-traefik.yaml
	kubectl apply -f /tmp/kubernetes/kubernetes-dashboard

	echo -e "\n${BLUE}Longhorn:${NC}"
	kubectl apply -f /tmp/kubernetes/longhorn/longhorn-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/longhorn/longhorn-traefik.yaml
	kubectl apply -f /tmp/kubernetes/longhorn
	kubectl patch daemonset -n longhorn-system longhorn-manager --type=json -p='[{"op": "remove", "path": "/spec/template/spec/tolerations"}]'

	echo -e "\n${BLUE}Waiting for Longhorn to Boot:${NC}"
	while [ "$(kubectl get pods -n longhorn-system | grep -v Running | wc -l)" -ne 1 ]; do
		sleep 1
	done

	echo -e "\n${BLUE}Prometheus:${NC}"
	kubectl apply -f /tmp/kubernetes/prometheus/prometheus-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/prometheus/prometheus-traefik.yaml
	kubectl apply -f /tmp/kubernetes/prometheus

	echo -e "\n${BLUE}Image Version Checker:${NC}"
	kubectl apply -f /tmp/kubernetes/version-checker/version-checker-namespace.yaml
	kubectl apply -f /tmp/kubernetes/version-checker

	echo -e "\n${BLUE}Grafana:${NC}"
	kubectl apply -f /tmp/kubernetes/grafana/grafana-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/grafana/grafana-traefik.yaml
	kubectl apply -f /tmp/kubernetes/grafana
	kubectl patch deployment -n grafana grafana --type=json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/env"}]'

	echo -e "\n${BLUE}Grafana Loki:${NC}"
	kubectl apply -f /tmp/kubernetes/grafana-loki

	echo -e "\n${BLUE}Grafana Promtail:${NC}"
	kubectl apply -f /tmp/kubernetes/grafana-promtail

	echo -e "\n\n${BLUE}Addons Installed!${NC}"
}

install_addons_optional() {
	load_kubeconfig

	echo -e "\n${BLUE}Heimdall:${NC}"
	kubectl apply -f /tmp/kubernetes/heimdall/heimdall-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/heimdall/heimdall-traefik.yaml
	sed -i "s/replicas: 1/replicas: 0/g" /tmp/kubernetes/heimdall/heimdall-statefulSet.yaml
	kubectl apply -f /tmp/kubernetes/heimdall
	kubectl patch statefulset -n heimdall heimdall --type=json -p='[{"op": "remove", "path": "/spec/template/spec/affinity"}]'
	kubectl patch statefulset -n heimdall heimdall --type=json -p='[{"op": "remove", "path": "/spec/template/spec/tolerations"}]'
	kubectl scale --replicas=1 statefulSet/heimdall -n heimdall

	echo -e "\n${BLUE}Uptime Kuma:${NC}"
	kubectl apply -f /tmp/kubernetes/uptime-kuma/uptime-kuma-namespace.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/uptime-kuma/uptime-kuma-traefik.yaml
	sed -i "s/replicas: 1/replicas: 0/g" /tmp/kubernetes/uptime-kuma/uptime-kuma-statefulSet.yaml
	kubectl apply -f /tmp/kubernetes/uptime-kuma
	kubectl patch statefulset -n uptime-kuma uptime-kuma --type=json -p='[{"op": "remove", "path": "/spec/template/spec/affinity"}]'
	kubectl patch statefulset -n uptime-kuma uptime-kuma --type=json -p='[{"op": "remove", "path": "/spec/template/spec/tolerations"}]'
	kubectl scale --replicas=1 statefulSet/uptime-kuma -n uptime-kuma
}

get_dashboard_secret() {
	load_kubeconfig
	echo -e "\n${BLUE}Kubernetes Dashboard Secret:${NC}"
	kubectl get secret -n kubernetes-dashboard \
		$(kubectl get serviceaccount admin-user -n kubernetes-dashboard -o jsonpath="{.secrets[0].name}") \
		-o jsonpath="{.data.token}" | base64 --decode
}

preseed_server() {
	echo -e "\n${BLUE}Loading Preseed Server:${NC}"
	echo -n Password:
	read -r -s PASSWORD
	echo ""

	# Startup Preseed Web Server
	mkdir -p /tmp/preseed/
	cp machineConfigs/preseed.cfg /tmp/preseed//preseed.cfg
	mkpasswd -m md5 "${PASSWORD}"
	sed -i "s,#d-i passwd/user-password-crypted password <HASH>,d-i passwd/user-password-crypted password $(mkpasswd -s -m md5 ${PASSWORD}),g" "/tmp/preseed/preseed.cfg"
	python3 -m http.server --directory /tmp/preseed/
}

install_cluster() {
	echo -e "\n${BLUE}Installing Cluster:${NC}"
	echo -n Password:
	read -r -s PASSWORD
	echo ""

	# IP Counter
	IP=${START_IP}

	# Delete Cluster If Exists
	delete_cluster

	mkdir -p "${HOME}/vm/${PREFIX}"

	for NODE in ${NODES}; do
		echo -e "\n\n${BLUE}Creating: ${PREFIX}${NODE}${NC}"

		if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
			CPU=2
			MEMORY=2560
			DISK=10
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			CPU=2
			MEMORY=4096
			DISK=30
		fi

		# Install VM
		#--debug \
		#--wait=-1 \
		virt-install \
			--noautoconsole \
			--graphics vnc \
			--name="${PREFIX}${NODE}" \
			--os-variant=debian11 \
			--vcpus sockets=1,cores=1,threads="${CPU}" \
			--ram="${MEMORY}" \
			--disk "${HOME}/vm/${PREFIX}/${PREFIX}${NODE}".img,size="${DISK}" \
			--network network=default,model=virtio,mac="10:10:00:00:00:${IP}" \
			--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
			--extra-args="\
	  auto=true priority=critical vga=normal hostname=${PREFIX}${NODE} \
	  url=http://10.10.10.1:8000/preseed.cfg"
		# https://crysol.org/recipe/2012-12-25/virtual-machine-unattended-debian-installations-with-libvirt-and-d-i-preseeding.html

		((IP++))
	done

	# Wait for Machines to Finish Installing OS, Then Boot Machines
	echo -e "\n\n${BLUE}Booting Nodes:${NC}"
	echo "Waiting for Installation to Finish..."
	echo "http://localhost:9090/machines"
	for NODE in ${NODES}; do
		# https://serverfault.com/a/386867
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 5
			if [ "$(virsh list --all | grep 'running' | grep "${PREFIX}${NODE}" | wc -c)" -eq 0 ]; then
				echo "Starting vm ${PREFIX}${NODE}"
				sleep 1
				virsh start "${PREFIX}${NODE}"
				finished=1
			fi
		done
	done

	# Add Machines to Known Hosts
	echo -e "\n\n${BLUE}Add SSH Known Hosts:${NC}"
	IP=${START_IP}
	for NODE in ${NODES}; do
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 1
			if nc -z 10.10.10.${IP} 22; then
				ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "10.10.10.${IP}"
				ssh-keyscan 10.10.10.${IP} >>"${HOME}/.ssh/known_hosts"
				finished=1
			fi
		done
		((IP++))
	done

	# Run Playbooks On All Machines
	ansible_sandbox
	reboot_cluster

}

install_k3s_cluster() {

	export PREFIX="sk3s"       # Sandbox k3s
	export K3S_TOKEN=${PREFIX} # Sandbox k3s
	export NODES="-master-0 -master-1 -master-2 -worker-0 -worker-1 -worker-2 -worker-3"

	install_cluster

	# Install & Setup k3s
	install_k3s

	export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml

	while [ "$(kubectl get nodes | wc -l)" -le "$(echo ${NODES} | wc -w)" ]; do
		sleep 1
	done

	# Label Nodes
	label_vms

	# Install Addons
	install_addons
	install_addons_optional

	get_dashboard_secret

	echo " "
	echo "export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
	echo "${PREFIX} k3s Install Complete!"
}

install_k8s_cluster() {

	export PREFIX="sk8s" # Sandbox k8s
	export NODES="-master-0 -master-1 -master-2 -worker-0 -worker-1 -worker-2 -worker-3"

	install_cluster

	# Install & Setup k8s
	install_k8s

	export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml

	while [ "$(kubectl get nodes | wc -l)" -le "$(echo ${NODES} | wc -w)" ]; do
		sleep 1
	done

	# Label Nodes
	label_vms

	load_kubeconfig
	kubectl -n kube-system rollout restart deployment coredns
	kubectl apply -f /tmp/kubernetes/kube-metrics-server

	# Install Addons
	install_addons
	install_addons_optional

	get_dashboard_secret

	echo " "
	echo "export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
	echo "${PREFIX} k8s Install Complete!"
}

install_okd() {
	# https://blog.maumene.org/2020/11/18/OKD-or-OpenShit-in-one-box.html
	# ssh -i ~/.ssh/id_ed25519 core@10.10.10.10
	# journalctl -b -f -u kubelet.service -u ciro.service
	export HOME=/home/arthur

	mkdir -p /vm
	chown -R arthur:arthur /vm/
	chmod 777 -R /vm/

	export PREFIX=""
	export NODES="bootstrap master-1 worker-1" #bootstrap master-1 master-2 master-3 worker-1 worker-2
	export MASTERS=1
	export WORKERS=1
	export START_IP=11

	if [[ $(/usr/bin/id -u) -ne 0 ]]; then
		echo "Not running as root"
		exit
	fi

	echo -e "\n\n${BLUE}Get URL:${NC}"
	URL=${URL:-}
	if [ -z "${URL}" ]; then
		echo -n URL:
		read -r -s URL
		echo ""
	fi
	echo "${URL}"

	# Expand Swap Size on Host Computer
	# if ! test -f "/tmp/swapfile.img"; then
	# 	dd if=/dev/zero of=/tmp/swapfile.img bs=25600 count=1M
	# 	mkswap /tmp/swapfile.img
	# 	swapon /tmp/swapfile.img
	# fi

	# Delete Cluster If Exists
	delete_cluster

	echo -e "\n\n${BLUE}Delete All Existing Data:${NC}"
	rm -rf /vm/okd/okd
	rm -rf /vm/okd/*.qcow2
	rm -rf /vm/okd/*.raw
	rm -rf /vm/okd/fedora-coreos-*
	rm -rf /vm/okd/openshift-install-linux* /vm/okd/openshift-client-linux* /vm/okd/oc /vm/okd/kubectl /vm/okd/openshift-install
	echo -e "\n\n${BLUE}Add SSH Known Hosts:${NC}"
	IP=$((START_IP - 1))
	for NODE in ${NODES}; do
		if [ "$NODE" = "worker-1" ]; then
			IP=$((START_IP + 3))
		fi
		ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "10.10.10.${IP}"
		((IP++))
	done

	echo -e "\n\n${BLUE}Download Dependencies:${NC}"
	# Download the latest Fedora CoreOS
	COREOS=35.20220227.3.0
	wget https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/"${COREOS}"/x86_64/fedora-coreos-"${COREOS}"-qemu.x86_64.qcow2.xz -P /vm/okd/
	xz -d /vm/okd/fedora-coreos-*.xz
	# Download openshift-install and openshift-client
	wget "$(curl https://api.github.com/repos/openshift/okd/releases/latest | grep openshift-install-linux | grep browser_download_url | cut -d\" -f4)" -P /vm/okd/
	wget "$(curl https://api.github.com/repos/openshift/okd/releases/latest | grep openshift-client-linux | grep browser_download_url | cut -d\" -f4)" -P /vm/okd/
	tar xvzf /vm/okd/openshift-install-linux* -C /vm/okd
	tar xvzf /vm/okd/openshift-client-linux* -C /vm/okd

	echo -e "\n\n${BLUE}Create Config Files:${NC}"
	# Create okd directory of openshift-install files
	mkdir -p /vm/okd/okd
	# Copy the install-config.yaml
	cp okd/install-config.yaml /vm/okd/okd/

	SSH=$(cat ${HOME}/.ssh/id_ed25519.pub)
	sed -i "s/<SSH>/${SSH}/g" /vm/okd/okd/install-config.yaml
	sed -i "s/<URL>/${URL}/g" /vm/okd/okd/install-config.yaml
	sed -i "s/<MASTERS>/${MASTERS}/g" /vm/okd/okd/install-config.yaml
	sed -i "s/<WORKERS>/${WORKERS}/g" /vm/okd/okd/install-config.yaml
	cp /vm/okd/okd/install-config.yaml /vm/okd/okd/install-config_backup.yaml

	# Create the ignition files
	/vm/okd/openshift-install create ignition-configs --dir=/vm/okd/okd

	chown -R arthur:arthur /vm/okd
	chmod 777 -R /vm/okd

	echo -e "\n\n${BLUE}Start OKD Install:${NC}"
	IP=${START_IP}
	for NODE in ${NODES}; do
		IMAGE="/vm/okd/${NODE}.raw"
		VCPUS="4"
		RAM_MB="12288"
		SIZE="50G"
		STORAGE=''

		if [[ "${NODE}" =~ "master" ]]; then
			IGNITION_CONFIG="/vm/okd/okd/master.ign"
		fi

		if [[ "${NODE}" =~ "worker" ]]; then
			VCPUS="4"
			RAM_MB="6144"
			IGNITION_CONFIG="/vm/okd/okd/worker.ign"
			/vm/okd/openshift-install --dir=/vm/okd/okd wait-for bootstrap-complete --log-level debug

			STORAGE_PATH="/vm/okd/${NODE}_storage.raw"
			STORAGE_SIZE="50G"
			qemu-img create "${STORAGE_PATH}" "${STORAGE_SIZE}" -f raw
			STORAGE="--disk=\"${STORAGE_PATH}\"",cache=none
		fi

		if [ "$NODE" = "worker-1" ]; then
			echo -e "\n\n${BLUE}Remove Bootstrap:${NC}"
			sleep 30
			virsh destroy bootstrap
			virsh undefine bootstrap --remove-all-storage
			echo -e "\n\n${BLUE}Deploying Workers:${NC}"
			IP=$((START_IP + 3))
		fi
		MAC="10:10:00:00:00:$IP"

		if [ "$NODE" = "bootstrap" ]; then
			IGNITION_CONFIG="/vm/okd/okd/bootstrap.ign"
			MAC="10:10:00:00:00:10"
			VCPUS="5"
		fi

		qemu-img create "${IMAGE}" "${SIZE}" -f raw
		virt-resize --expand /dev/sda4 /vm/okd/fedora-coreos-*.qcow2 "${IMAGE}"

		virt-install \
			--connect="qemu:///system" \
			--name="${NODE}" \
			--vcpus="${VCPUS}" --memory="${RAM_MB}" \
			--os-variant="fedora-coreos-stable" \
			--import --graphics="none" \
			--network network=default,model=virtio,mac="${MAC}" \
			--disk="${IMAGE},cache=none" ${STORAGE} \
			--cpu="host-passthrough" \
			--noautoconsole \
			--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}"

		if [ "$NODE" != "bootstrap" ]; then
			IP=$((IP + 1))
		fi

	done
	chown -R arthur:arthur /vm/okd
	chmod 777 -R /vm/okd

	/vm/okd/openshift-install --dir=/vm/okd/okd wait-for install-complete --log-level debug

	export KUBECONFIG="/vm/okd/okd/auth/kubeconfig"
	/vm/okd/oc apply -f okd/okd-configuration/operator-hub.yaml

	# https://github.com/openshift/okd/issues/963#issuecomment-1073120091
	/vm/okd/oc delete mc 99-master-okd-extensions 99-okd-master-disable-mitigations

	single_server
}

single_server() {
	echo -e "\n\n${BLUE}Single Server Resource Adjustments:${NC}"
	export KUBECONFIG="/vm/okd/okd/auth/kubeconfig"
	/vm/okd/oc scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator
	/vm/okd/oc scale --replicas=1 deployment.apps/console -n openshift-console
	/vm/okd/oc scale --replicas=1 deployment.apps/downloads -n openshift-console
	/vm/okd/oc scale --replicas=1 deployment.apps/oauth-openshift -n openshift-authentication
	/vm/okd/oc scale --replicas=1 deployment.apps/packageserver -n openshift-operator-lifecycle-manager

	/vm/okd/oc scale --replicas=1 deployment.apps/prometheus-adapter -n openshift-monitoring
	/vm/okd/oc scale --replicas=1 deployment.apps/thanos-querier -n openshift-monitoring
	/vm/okd/oc scale --replicas=1 statefulset.apps/prometheus-k8s -n openshift-monitoring
	/vm/okd/oc scale --replicas=1 statefulset.apps/alertmanager-main -n openshift-monitoring
}

approve_csr() {
	echo -e "\n\n${BLUE}Approving CSRs:${NC}"
	while true; do
		for csr in $(oc get csr 2>/dev/null | grep -w 'Pending' | awk '{print $1}'); do
			echo -n '  --> Approving CSR: '
			oc adm certificate approve "$csr" 2>/dev/null || true
		done
		sleep 5
	done
}

"$@"
