#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# PRESEED CONFIG: /machineConfigs/server/preseed.cfg
# ANSIBLE CONFIG: /ansible/k3s.yaml

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

BLUE='\033[1;34m'
NC='\033[0m'

export LIBVIRT_DEFAULT_URI=qemu:///system
export PREFIX="sk3s"       # Sandbox k3s
export K3S_TOKEN=${PREFIX} # Sandbox k3s
export NODES="-master-0 -master-1 -master-2 -worker-0 -worker-1 -worker-2 -worker-3"
export START_IP=3
PASSWORD=${PASSWORD:-}

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

ansible() {
	echo -e "\n${BLUE}Running Ansible Playbooks:${NC}"
	if [ -z "${PASSWORD}" ]; then
		echo -n Password:
		read -r -s PASSWORD
		echo ""
	fi
	IP=${START_IP}
	# Create Ansible Inventory File
	echo "[k3s]" >/tmp/inventory
	for NODE in ${NODES}; do
		echo "10.10.10.${IP}" >>/tmp/inventory
		((IP++))
	done
	# Run Playbooks On All Machines
	ansible-playbook -i /tmp/inventory ansible/k3s.yaml --extra-vars \
		"ansible_become_pass=${PASSWORD} ansible_ssh_pass=${PASSWORD}"
}

label_nodes() {
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
	K3S_CONFIG="K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_CHANNEL=v1.22 sh -"

	INSTALL="${K3S} server --cluster-init --disable traefik ${K3S_RESERVED} ${K3S_CONFIG}"
	SERVER=" ${K3S} server --server https://10.10.10.3:6443 --disable traefik ${K3S_RESERVED} ${K3S_CONFIG}"
	WORKER=" ${K3S} ${K3S_RESERVED} K3S_URL=https://10.10.10.3:6443 ${K3S_CONFIG}"

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
			sed -i "s,127.0.0.1,10.10.10.${START_IP},g" "${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
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

	echo -e "\n${BLUE}Kube System:${NC}"
	kubectl patch deployment -n kube-system metrics-server --patch \
		"$(cat /tmp/kubernetes/kube-system/metrics-server-deployment.yaml)"
	kubectl apply -f /tmp/kubernetes/kube-system/kube-system-limitRange.yaml
	kubectl apply -f /tmp/kubernetes/kube-system/kube-system-resourceQuota.yaml

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
	sed -i "s[node-role.kubernetes.io/master:NoSchedule[[g" /tmp/kubernetes/longhorn/longhorn-configmap.yaml
	sed -i "s[tolerations:[[g" /tmp/kubernetes/longhorn/longhorn-deployment.yaml
	sed -i "s[- key: node-role.kubernetes.io/master[[g" /tmp/kubernetes/longhorn/longhorn-deployment.yaml
	sed -i "s[effect: NoSchedule[[g" /tmp/kubernetes/longhorn/longhorn-deployment.yaml
	kubectl apply -f /tmp/kubernetes/longhorn

	echo -e "\n${BLUE}Waiting for Longhorn to Boot:${NC}"
	while [ "$(kubectl get pods -n longhorn-system | grep -v Running | wc -l)" -ne 1 ]; do
		sleep 1
	done

	echo -e "\n${BLUE}Prometheus:${NC}"
	kubectl apply -f /tmp/kubernetes/prometheus/prometheus-namespace.yaml
	sed -i "s/- k3s-infra-ssd//g" /tmp/kubernetes/prometheus/prometheus-longhorn.yaml
	sed -i "s/diskSelector://g" /tmp/kubernetes/prometheus/prometheus-longhorn.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/prometheus/prometheus-traefik.yaml
	kubectl apply -f /tmp/kubernetes/prometheus

	echo -e "\n${BLUE}Image Version Checker:${NC}"
	kubectl apply -f /tmp/kubernetes/version-checker/version-checker-namespace.yaml
	kubectl apply -f /tmp/kubernetes/version-checker

	echo -e "\n${BLUE}Grafana:${NC}"
	kubectl apply -f /tmp/kubernetes/grafana/grafana-namespace.yaml
	sed -i "s/- k3s-server-usb//g" /tmp/kubernetes/grafana/grafana-longhorn.yaml
	sed -i "s/diskSelector://g" /tmp/kubernetes/grafana/grafana-longhorn.yaml
	sed -i "s/numberOfReplicas: 3/numberOfReplicas: 2/g" /tmp/kubernetes/grafana/grafana-longhorn.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/grafana/grafana-traefik.yaml
	kubectl apply -f /tmp/kubernetes/grafana

	echo -e "\n${BLUE}Grafana Loki:${NC}"
	sed -i "s/- k3s-infra-ssd//g" /tmp/kubernetes/grafana-loki/loki-longhorn.yaml
	sed -i "s/diskSelector://g" /tmp/kubernetes/grafana-loki/loki-longhorn.yaml
	kubectl apply -f /tmp/kubernetes/grafana-loki

	echo -e "\n${BLUE}Grafana Promtail:${NC}"
	kubectl apply -f /tmp/kubernetes/grafana-promtail

	echo -e "\n\n${BLUE}Addons Installed!${NC}"
}

install_addons_optional() {
	load_kubeconfig

	echo -e "\n${BLUE}Heimdall:${NC}"
	kubectl apply -f /tmp/kubernetes/heimdall/heimdall-namespace.yaml
	sed -i "s/- k3s-server-usb//g" /tmp/kubernetes/heimdall/heimdall-longhorn.yaml
	sed -i "s/diskSelector://g" /tmp/kubernetes/heimdall/heimdall-longhorn.yaml
	sed -i "s/numberOfReplicas: 3/numberOfReplicas: 2/g" /tmp/kubernetes/heimdall/heimdall-longhorn.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/heimdall/heimdall-traefik.yaml
	sed -i "s[tolerations:[[g" /tmp/kubernetes/heimdall/heimdall-statefulSet.yaml
	sed -i "s[- key: node-role.kubernetes.io/master[[g" /tmp/kubernetes/heimdall/heimdall-statefulSet.yaml
	sed -i "s[effect: NoSchedule[[g" /tmp/kubernetes/heimdall/heimdall-statefulSet.yaml
	kubectl apply -f /tmp/kubernetes/heimdall

	echo -e "\n${BLUE}Uptime Kuma:${NC}"
	kubectl apply -f /tmp/kubernetes/uptime-kuma/uptime-kuma-namespace.yaml
	sed -i "s/- k3s-server-ssd//g" /tmp/kubernetes/uptime-kuma/uptime-kuma-longhorn.yaml
	sed -i "s/diskSelector://g" /tmp/kubernetes/uptime-kuma/uptime-kuma-longhorn.yaml
	sed -i "s/numberOfReplicas: 3/numberOfReplicas: 2/g" /tmp/kubernetes/uptime-kuma/uptime-kuma-longhorn.yaml
	sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/uptime-kuma/uptime-kuma-traefik.yaml
	sed -i "s[tolerations:[[g" /tmp/kubernetes/uptime-kuma/uptime-kuma-statefulSet.yaml
	sed -i "s[- key: node-role.kubernetes.io/master[[g" /tmp/kubernetes/uptime-kuma/uptime-kuma-statefulSet.yaml
	sed -i "s[effect: NoSchedule[[g" /tmp/kubernetes/uptime-kuma/uptime-kuma-statefulSet.yaml
	kubectl apply -f /tmp/kubernetes/uptime-kuma
}

get_dashboard_secret() {
	load_kubeconfig
	echo -e "\n${BLUE}Kubernetes Dashboard Secret:${NC}"
	kubectl get secret -n kubernetes-dashboard \
		$(kubectl get serviceaccount admin-user -n kubernetes-dashboard -o jsonpath="{.secrets[0].name}") \
		-o jsonpath="{.data.token}" | base64 --decode
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
			CPU=1
			SIZE=10
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			SIZE=30
			CPU=2
		fi

		# Install VM
		#--debug \
		#--wait=-1 \
		virt-install \
			--noautoconsole \
			--name="${PREFIX}${NODE}" \
			--os-variant=debian11 \
			--vcpus sockets=1,cores=1,threads="${CPU}" \
			--ram=4096 \
			--disk "${HOME}/vm/${PREFIX}/${PREFIX}${NODE}".img,size="${SIZE}" \
			--network network=default,model=virtio,mac="10:10:00:00:00:0${IP}" \
			--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
			--extra-args="\
	  auto=true priority=critical vga=normal hostname=${PREFIX}${NODE} \
	  url=http://10.0.0.3:7071/preseed.cfg"
		# https://crysol.org/recipe/2012-12-25/virtual-machine-unattended-debian-installations-with-libvirt-and-d-i-preseeding.html

		((IP++))
	done

	# Wait for Machines to Finish Installing OS, Then Boot Machines
	echo -e "\n\n${BLUE}Booting Nodes:${NC}"
	echo "Waiting for Installation to Finish..."
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
	ansible
	reboot_cluster

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

	# Install & Setup k3s
	install_k3s

	export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml

	while [ "$(kubectl get nodes | wc -l)" -le "$(echo ${NODES} | wc -w)" ]; do
		sleep 1
	done

	# Label Nodes
	label_nodes

	# Install Addons
	install_addons
	# install_addons_optional
	get_dashboard_secret

	echo " "
	echo "export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
	echo "${PREFIX} k3s Install Complete!"
}

"$@"
