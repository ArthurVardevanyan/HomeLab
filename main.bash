#!/bin/bash

set -o errexit  # exit on any failure
set -o nounset  # exit on undeclared variables
set -o pipefail # return value of all commands in a pipe
## set -o xtrace  # command tracing
shopt -s failglob # If no matches are found, an error message is printed and the command is not executed

# PRESEED CONFIG: /machineConfigs/servers/preseed.cfg
# ANSIBLE CONFIG: /ansible/k3s.yaml

BLUE='\033[1;34m'
NC='\033[0m'

# https://www.how2shout.com/linux/how-to-install-and-configure-kvm-on-debian-11-bullseye-linux/
export LIBVIRT_DEFAULT_URI=qemu:///system
export SWAP_PATH=${SWAP_PATH:-"/home/swapfile.img"}

# HomeLab Functions
function retry {
  local retries=$1
  shift

  local count=0
  until "$@"; do
    exit=$?
    wait=$((15 + 5 ** count))
    count=$((count + 1))
    if [ $count -lt "$retries" ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}

ansible() {
  ansible-playbook -i ansible/inventory --ask-become-pass ansible/servers.yaml --ask-pass \
    -e 'ansible_python_interpreter=/usr/bin/python3'
}

function kustomize_fix() {
  local option="$1"
  local target_dir="${2:-}"

  if [[ "$option" == "--all" ]]; then
    find . -type f -name "kustomization.yaml" | while read -r FILE; do
      DIR=$(dirname "${FILE}")
      pushd "${DIR}" && kustomize edit fix --vars 1>/dev/null && popd
      if ! grep -q "^---" "$FILE"; then
        sed -i '1s/^/---\n/' "$FILE"
      fi
    done
    prettier ./ --write
  elif [[ "$option" == "--dir" ]]; then
    if [[ -z "$target_dir" ]]; then
      echo "Error: --dir requires a directory argument."
      return 1
    fi

    if [[ -d "$target_dir" ]]; then
      find "$target_dir" -type f -name "kustomization.yaml" | while read -r FILE; do
        DIR=$(dirname "${FILE}")
        pushd "${DIR}" && kustomize edit fix --vars 1>/dev/null && popd
        if ! grep -q "^---" "$FILE"; then
          sed -i '1s/^/---\n/' "$FILE"
        fi
      done
    else
      echo "Error: Specified directory does not exist."
      return 1
    fi
    prettier "./$target_dir" --write
  else
    echo "Error: Invalid option."
    return 1
  fi
}

test_overlays() {

  if [ -n "$VAULT_ADDR" ] && [ -n "$VAULT_TOKEN" ]; then
    DIR="/tmp/yaml"
    rm -rf /tmp/yaml
    mkdir -p /tmp/yaml
    echo "Build Yaml's"
    for OVERLAY in ./kubernetes/*/overlays/*; do # *
      echo "${OVERLAY}"
      OUTPUT=$(echo "${OVERLAY}" | sed 's/\.//g' | sed 's/\//_/g')
      kubectl kustomize "${OVERLAY}" | argocd-vault-plugin generate - >"${DIR}/${OUTPUT}.yaml"
    done
    for OVERLAY in ./okd/*/overlays/*; do
      echo "${OVERLAY}"
      OUTPUT=$(echo "${OVERLAY}" | sed 's/\.//g' | sed 's/\//_/g')
      kubectl kustomize "${OVERLAY}" | argocd-vault-plugin generate - >"${DIR}/${OUTPUT}.yaml"
    done
    for OVERLAY in ./tekton/overlays/*; do
      echo "${OVERLAY}"
      OUTPUT=$(echo "${OVERLAY}" | sed 's/\.//g' | sed 's/\//_/g')
      kubectl kustomize "${OVERLAY}" | argocd-vault-plugin generate - >"${DIR}/${OUTPUT}.yaml"
    done

    echo "Run KubeConform on Yaml's"
    #  -ignore-missing-schemas # -debug
    kubeconform -n 16 -verbose --summary -strict \
      -schema-location="../kubernetes-json-schema/custom-standalone-strict/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json" \
      -schema-location '../kubernetes-json-schema/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json' \
      -schema-location "../kubernetes-json-schema/master-local/{{.ResourceKind}}.json" \
      -output text "${DIR}" | grep -v "is valid"
  else
    echo "Vault Variables Missing"
    exit 1
  fi
}

test_overlays_k3s() {

  if [ -n "$VAULT_ADDR" ] && [ -n "$VAULT_TOKEN" ]; then
    DIR="/tmp/yaml"
    rm -rf /tmp/yaml
    mkdir -p /tmp/yaml
    echo "Build Yaml's"
    for OVERLAY in ./kubernetes/*/overlays/k3s; do # *
      echo "${OVERLAY}"
      OUTPUT=$(echo "${OVERLAY}" | sed 's/\.//g' | sed 's/\//_/g')
      kubectl kustomize "${OVERLAY}" | argocd-vault-plugin generate - >"${DIR}/${OUTPUT}.yaml"
    done
    echo "Run KubeConform on Yaml's"
    kubeconform -n 16 -verbose --summary -ignore-missing-schemas \
      -schema-location="../kubernetes-json-schema/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json" \
      -output text "${DIR}" | grep -v "is valid"

  else
    echo "Vault Variables Missing"
    exit 1
  fi
}
stateful_workload_stop() {
  # kubectl patch cronjobs -n netbox netbox-housekeeping -p '{"spec" : {"suspend" : true }}'
  kubectl patch cronjobs -n immich immich-cron -p '{"spec" : {"suspend" : true }}'
  kubectl patch cronjobs -n nextcloud nextcloud-preview -p '{"spec" : {"suspend" : true }}'
  kubectl patch cronjobs -n nextcloud nextcloud-rsync -p '{"spec" : {"suspend" : true }}'
  kubectl patch cronjobs -n nextcloud nextcloud-cron -p '{"spec" : {"suspend" : true }}'

  kubectl scale --replicas=0 -n openshift-monitoring deployment/cluster-monitoring-operator
  kubectl scale --replicas=0 -n openshift-monitoring deployment/prometheus-operator
  kubectl scale --replicas=0 -n openshift-monitoring statefulset/alertmanager-main
  kubectl scale --replicas=0 -n openshift-monitoring statefulset/prometheus-k8s
  kubectl scale --replicas=0 -n openshift-user-workload-monitoring deployment/prometheus-operator
  kubectl scale --replicas=0 -n openshift-user-workload-monitoring statefulset/alertmanager-user-workload
  kubectl scale --replicas=0 -n openshift-user-workload-monitoring statefulset/prometheus-user-workload
  kubectl scale --replicas=0 -n openshift-user-workload-monitoring statefulset/thanos-ruler-user-workload

  kubectl scale --replicas=0 -n bitwarden statefulset/bitwarden
  kubectl scale --replicas=0 -n gitea deployment/gitea
  kubectl scale --replicas=0 -n grafana deployment/grafana
  kubectl scale --replicas=0 -n heimdall statefulset/heimdall
  kubectl scale --replicas=0 -n homeassistant statefulset/homeassistant
  # kubectl scale --replicas=0 -n loki statefulset/loki
  kubectl scale --replicas=0 -n nextcloud deployment/nextcloud
  kubectl scale --replicas=0 -n immich statefulset/immich
  kubectl scale --replicas=0 -n prometheus statefulset/prometheus
  kubectl scale --replicas=0 -n prometheus statefulset/thanos-store-gateway
  kubectl scale --replicas=0 -n prometheus statefulset/prometheus-truenas
  kubectl scale --replicas=0 -n prometheus statefulset/thanos-truenas-store-gateway
  kubectl scale --replicas=0 -n uptime-kuma statefulset/uptime-kuma
  kubectl scale --replicas=0 -n vault statefulset/vault

  kubectl scale --replicas=0 -n pihole statefulset/pihole
  kubectl scale --replicas=0 -n pihole statefulset/pihole-vlan3
  kubectl scale --replicas=0 -n technitium-dns statefulset/technitium-dns

  kubectl scale --replicas=0 -n external-dns deployment/external-dns-microshift
  kubectl scale --replicas=0 -n external-dns deployment/external-dns-microshift-vlan3
  kubectl scale --replicas=0 -n external-dns deployment/external-dns-okd
  kubectl scale --replicas=0 -n external-dns deployment/external-dns-okd-vlan3

  kubectl scale --replicas=0 -n ntp deployment/ntp-rootless
  kubectl scale --replicas=0 -n cloudflare-ddns deployment/cloudflare-ddns

  #kubectl scale --replicas=0 -n minio-operator deployment/minio-operator
  kubectl scale --replicas=0 -n quay deployment/quay-operator-tng
  kubectl scale --replicas=0 -n quay deployment/quay-quay-app
  kubectl scale --replicas=0 -n quay deployment/quay-clair-app
  kubectl scale --replicas=0 -n quay deployment/quay-quay-mirror

  # kubectl scale --replicas=0 -n cockroach-operator-system deployments/cockroach-operator-manager
  # kubectl scale --replicas=0 -n zitadel statefulset/crdb
  kubectl scale --replicas=0 -n zitadel deployment/zitadel

  # kubectl scale --replicas=0 -n mongodb-operator deployments/mongodb-kubernetes-operator
  # kubectl scale --replicas=0 -n unifi-network-application statefulset/unifi-network-application
  # kubectl scale --replicas=0 -n unifi-network-application statefulset/mongo-unifi-network-application

  kubectl patch postgresCluster clair -n quay --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster gitea -n gitea --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster grafana -n grafana --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster homeassistant -n homeassistant --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster nextcloud -n nextcloud --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster immich -n immich --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster stackrox -n stackrox --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster quay -n quay --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster zitadel -n zitadel --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster finance -n finance-tracker --type=merge -p '{"spec":{"shutdown":true}}'
  kubectl patch postgresCluster spotify -n analytics-for-spotify --type=merge -p '{"spec":{"shutdown":true}}'
  # kubectl patch postgresCluster awx -n awx --type=merge -p '{"spec":{"shutdown":true}}'
  # kubectl patch postgresCluster netbox -n netbox --type=merge -p '{"spec":{"shutdown":true}}'

  kubectl scale --replicas=0 -n argocd deployment/argocd-operator-controller-manager
  kubectl scale --replicas=0 -n argocd statefulset/argocd-application-controller
  kubectl scale --replicas=0 -n argocd deployment/argocd-notifications-controller
  kubectl scale --replicas=0 -n argocd deployment/argocd-repo-server
  kubectl scale --replicas=0 -n argocd deployment/argocd-dex-server
  kubectl scale --replicas=0 -n argocd deployment/argocd-server

  kubectl scale --replicas=0 -n argocd-apps statefulset/argocd-apps-application-controller
  kubectl scale --replicas=0 -n argocd-apps deployment/argocd-apps-dex-server
  kubectl scale --replicas=0 -n argocd-apps deployment/argocd-apps-repo-server
  kubectl scale --replicas=0 -n argocd-apps deployment/argocd-apps-server

  kubectl scale --replicas=0 -n stackrox deployment/central
  kubectl scale --replicas=0 -n stackrox deployment/scanner-db

  kubectl scale --replicas=0 -n dragonfly-operator-system deployment/dragonfly-operator-controller-manager
  kubectl scale --replicas=0 -n nextcloud statefulset/nextcloud-dragonfly
  kubectl scale --replicas=0 -n gitea statefulset/gitea-dragonfly
  kubectl scale --replicas=0 -n quay statefulset/quay-dragonfly
  # kubectl scale --replicas=0 -n netbox statefulset/netbox-dragonfly

  kubectl scale --replicas=0 -n loki-operator deployment/loki-operator-controller-manager
  kubectl scale --replicas=0 -n network-observability-loki statefulset/netobserv-compactor
  kubectl scale --replicas=0 -n network-observability-loki statefulset/netobserv-index-gateway
  kubectl scale --replicas=0 -n network-observability-loki statefulset/netobserv-ingester
  kubectl scale --replicas=0 -n network-observability-loki deployment/netobserv-distributor
  kubectl scale --replicas=0 -n network-observability-loki deployment/netobserv-gateway
  kubectl scale --replicas=0 -n network-observability-loki deployment/netobserv-querier
  kubectl scale --replicas=0 -n network-observability-loki deployment/netobserv-query-frontend

  kubectl scale --replicas=0 -n openshift-logging statefulset/logging-loki-compactor
  kubectl scale --replicas=0 -n openshift-logging statefulset/logging-loki-index-gateway
  kubectl scale --replicas=0 -n openshift-logging statefulset/logging-loki-ingester
  kubectl scale --replicas=0 -n openshift-logging deployment/logging-loki-distributor
  kubectl scale --replicas=0 -n openshift-logging deployment/logging-loki-gateway
  kubectl scale --replicas=0 -n openshift-logging deployment/logging-loki-querier
  kubectl scale --replicas=0 -n openshift-logging deployment/logging-loki-query-frontend

  # kubectl scale --replicas=0 -n awx deployment/awx-operator-controller-manager
  # kubectl scale --replicas=0 -n awx deployment/awx-task
  # kubectl scale --replicas=0 -n awx deployment/awx-web

  # kubectl scale --replicas=0 -n netbox deployment/netbox
  # kubectl scale --replicas=0 -n netbox deployment/netbox-worker

  kubectl delete jobs -A --all
  kubectl delete pipelineruns -A --all
}

stateful_workload_start_pre() {
  # kubectl scale --replicas=1 -n cockroach-operator-system deployments/cockroach-operator-manager
  # kubectl scale --replicas=3 -n zitadel statefulset/crdb

  # kubectl scale --replicas=1 -n mongodb-operator deployments/mongodb-kubernetes-operator
  # kubectl scale --replicas=3 -n unifi-network-application statefulset/mongo-unifi-network-application

  # kubectl scale --replicas=1 -n loki statefulset/loki
  kubectl scale --replicas=1 -n prometheus statefulset/prometheus
  kubectl scale --replicas=1 -n prometheus statefulset/thanos-store-gateway
  kubectl scale --replicas=1 -n quay deployment/quay-operator-tng
  kubectl scale --replicas=1 -n postgres deployment/pgo

  kubectl patch postgresCluster clair -n quay --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster quay -n quay --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster homeassistant -n homeassistant --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster gitea -n gitea --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster grafana -n grafana --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster nextcloud -n nextcloud --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster immich -n immich --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster stackrox -n stackrox --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster finance -n finance-tracker --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster spotify -n analytics-for-spotify --type=merge -p '{"spec":{"shutdown":false}}'
  # kubectl patch postgresCluster awx -n awx --type=merge -p '{"spec":{"shutdown":false}}'
  # kubectl patch postgresCluster netbox -n netbox --type=merge -p '{"spec":{"shutdown":false}}'

  kubectl scale --replicas=1 -n pihole statefulset/pihole
  kubectl scale --replicas=1 -n pihole statefulset/pihole-vlan3
  kubectl scale --replicas=1 -n technitium-dns statefulset/technitium-dns

  kubectl scale --replicas=2 -n ntp deployment/ntp-rootless
}

stateful_workload_start() {

  kubectl scale --replicas=1 -n pihole statefulset/pihole
  kubectl scale --replicas=1 -n pihole statefulset/pihole-vlan3
  kubectl scale --replicas=1 -n technitium-dns statefulset/technitium-dns

  kubectl scale --replicas=2 -n external-dns deployment/external-dns-microshift
  kubectl scale --replicas=2 -n external-dns deployment/external-dns-microshift-vlan3
  kubectl scale --replicas=2 -n external-dns deployment/external-dns-okd
  kubectl scale --replicas=2 -n external-dns deployment/external-dns-okd-vlan3

  kubectl scale --replicas=2 -n cloudflare-ddns deployment/cloudflare-ddns

  # kubectl patch cronjobs -n netbox netbox-housekeeping -p '{"spec" : {"suspend" : false }}'
  kubectl patch cronjobs -n immich immich-cron -p '{"spec" : {"suspend" : false }}'
  kubectl patch cronjobs -n nextcloud nextcloud-preview -p '{"spec" : {"suspend" : false }}'
  kubectl patch cronjobs -n nextcloud nextcloud-rsync -p '{"spec" : {"suspend" : false }}'
  kubectl patch cronjobs -n nextcloud nextcloud-cron -p '{"spec" : {"suspend" : false }}'

  kubectl scale --replicas=1 -n openshift-monitoring deployment/cluster-monitoring-operator

  kubectl scale --replicas=1 -n dragonfly-operator-system deployment/dragonfly-operator-controller-manager
  kubectl scale --replicas=2 -n nextcloud statefulset/nextcloud-dragonfly
  kubectl scale --replicas=2 -n gitea statefulset/gitea-dragonfly
  kubectl scale --replicas=2 -n quay statefulset/quay-dragonfly
  # kubectl scale --replicas=2 -n netbox statefulset/netbox-dragonfly

  # kubectl scale --replicas=1 -n cockroach-operator-system deployments/cockroach-operator-manager
  # kubectl scale --replicas=3 -n zitadel statefulset/crdb
  kubectl scale --replicas=2 -n zitadel deployment/zitadel

  # kubectl scale --replicas=1 -n mongodb-operator deployments/mongodb-kubernetes-operator
  # kubectl scale --replicas=3 -n unifi-network-application statefulset/mongo-unifi-network-application
  # kubectl scale --replicas=1 -n unifi-network-application statefulset/unifi-network-application

  kubectl scale --replicas=1 -n bitwarden statefulset/bitwarden
  kubectl scale --replicas=2 -n gitea deployment/gitea
  kubectl scale --replicas=2 -n grafana deployment/grafana
  kubectl scale --replicas=1 -n heimdall statefulset/heimdall
  kubectl scale --replicas=1 -n homeassistant statefulset/homeassistant
  kubectl scale --replicas=1 -n loki statefulset/loki
  kubectl scale --replicas=2 -n nextcloud deployment/nextcloud
  kubectl scale --replicas=1 -n immich statefulset/immich
  kubectl scale --replicas=1 -n prometheus statefulset/prometheus
  kubectl scale --replicas=1 -n prometheus statefulset/thanos-store-gateway
  kubectl scale --replicas=1 -n prometheus statefulset/prometheus-truenas
  kubectl scale --replicas=1 -n prometheus statefulset/thanos-truenas-store-gateway
  kubectl scale --replicas=1 -n uptime-kuma statefulset/uptime-kuma
  kubectl scale --replicas=3 -n vault statefulset/vault
  #kubectl scale --replicas=1 -n minio-operator deployment/minio-operator
  kubectl scale --replicas=1 -n quay deployment/quay-operator-tng
  kubectl scale --replicas=2 -n quay deployment/quay-quay-app
  kubectl scale --replicas=2 -n quay deployment/quay-clair-app
  kubectl scale --replicas=2 -n quay deployment/quay-quay-mirror
  kubectl scale --replicas=1 -n postgres deployment/pgo

  kubectl patch postgresCluster clair -n quay --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster quay -n quay --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster homeassistant -n homeassistant --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster gitea -n gitea --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster grafana -n grafana --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster nextcloud -n nextcloud --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster immich -n immich --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster stackrox -n stackrox --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster finance -n finance-tracker --type=merge -p '{"spec":{"shutdown":false}}'
  kubectl patch postgresCluster spotify -n analytics-for-spotify --type=merge -p '{"spec":{"shutdown":false}}'
  # kubectl patch postgresCluster awx -n awx --type=merge -p '{"spec":{"shutdown":false}}'
  # kubectl patch postgresCluster netbox -n netbox --type=merge -p '{"spec":{"shutdown":false}}'

  kubectl scale --replicas=1 -n argocd deployment/argocd-operator-controller-manager
  kubectl scale --replicas=1 -n argocd statefulset/argocd-application-controller
  kubectl scale --replicas=1 -n argocd statefulset/argocd-application-controller
  kubectl scale --replicas=1 -n argocd deployment/argocd-repo-server
  kubectl scale --replicas=1 -n argocd deployment/argocd-dex-server
  kubectl scale --replicas=1 -n argocd deployment/argocd-server

  kubectl scale --replicas=1 -n argocd-apps statefulset/argocd-apps-application-controller
  kubectl scale --replicas=1 -n argocd-apps deployment/argocd-apps-dex-server
  kubectl scale --replicas=1 -n argocd-apps deployment/argocd-apps-repo-server
  kubectl scale --replicas=1 -n argocd-apps deployment/argocd-apps-server

  kubectl scale --replicas=1 -n stackrox deployment/central
  kubectl scale --replicas=1 -n stackrox deployment/scanner-db

  kubectl scale --replicas=1 -n loki-operator deployment/loki-operator-controller-manager
  # kubectl scale --replicas=1 -n awx deployment/awx-operator-controller-manager

  # kubectl scale --replicas=1 -n awx deployment/netbox
  # kubectl scale --replicas=1 -n awx deployment/netbox-worker

  # echo -e "\nkubectl exec -it vault-0 -n vault -- vault operator unseal --tls-skip-verify"
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
    --disk "/mnt/storage/vm/k3s-server-2".img,,format=raw,size=25 \
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
    --disk "/mnt/storage/vm/k3s-worker-1".img,,format=raw,size=125 \
    --network bridge=br0,mac="10:00:00:00:01:11" \
    --location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
    --extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-worker-1 \
            url=http://10.0.0.5:7071/preseed.cfg"

}

kvm() {
  ssh 10.101.1.6

  export LIBVIRT_DEFAULT_URI=qemu:///system

  virt-install \
    --noautoconsole \
    --graphics vnc \
    --name=k3s-server-3 \
    --os-variant=debian10 \
    --vcpus sockets=1,cores=1,threads=2 \
    --ram=1792 \
    --disk "/mnt/storage/vm/k3s-server-3".img,,format=raw,size=25 \
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
    --disk "/mnt/storage/vm/k3s-worker-2".img,,format=raw,size=125 \
    --network bridge=br0,mac="10:00:00:00:01:12" \
    --location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
    --extra-args="\
            auto=true priority=critical vga=normal hostname=k3s-worker-2 \
            url=http://10.0.0.5:7071/preseed.cfg"
}

label_nodes() {
  # Taint
  kubectl taint node k3s-server-1 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
  kubectl taint node k3s-server-2 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
  kubectl taint node k3s-server-3 node-role.kubernetes.io/control-plane:NoSchedule --overwrite
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

  for IP in ${IP_LIST}; do
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
      kubectl taint node "${PREFIX}${NODE}" node-role.kubernetes.io/control-plane:NoSchedule --overwrite
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
  export KUBECONFIG=/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml
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
      sshpass -p "${PASSWORD}" scp 10.10.10.${START_IP}:/tmp/k3s.yaml "/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml"
      sed -i "s,127.0.0.1,10.10.10.1,g" "/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml"
    fi
    ((IP++))
  done

  echo -e "\n\n${BLUE}Install Complete!${NC}"
  echo "export KUBECONFIG=/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml"
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
  while [ "$(kubectl get pods -n longhorn-system | grep -cv Running)" -ne 1 ]; do
    sleep 1
  done

  echo -e "\n${BLUE}Prometheus:${NC}"
  kubectl apply -f /tmp/kubernetes/prometheus/prometheus-namespace.yaml
  sed -i "s/<URL>/${URL}/g" /tmp/kubernetes/prometheus/prometheus-traefik.yaml
  kubectl apply -f /tmp/kubernetes/prometheus

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
  # shellcheck disable=SC2046
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
  sed -i "s,#d-i passwd/user-password-crypted password <HASH>,d-i passwd/user-password-crypted password $(mkpasswd -s -m md5 "${PASSWORD}"),g" "/tmp/preseed/preseed.cfg"
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

  mkdir -p "/mnt/storage/vm/${PREFIX}"

  for NODE in ${NODES}; do
    echo -e "\n\n${BLUE}Creating: ${PREFIX}${NODE}${NC}"

    if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
      CPU=3
      MEMORY=4096
      DISK=15
    elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
      CPU=6
      MEMORY=8192
      DISK=30
    fi

    # Install VM
    #--debug \
    #--wait=-1 \
    # shellcheck disable=SC2140
    virt-install \
      --noautoconsole \
      --graphics vnc \
      --name="${PREFIX}${NODE}" \
      --os-variant=debian11 \
      --vcpus sockets=1,cores=1,threads="${CPU}" \
      --ram="${MEMORY}" \
      --disk "/mnt/storage/vm/${PREFIX}/${PREFIX}${NODE}".img,size="${DISK}" \
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

  export KUBECONFIG="/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml"

  while [ "$(kubectl get nodes | wc -l)" -le "$(echo "${NODES}" | wc -w)" ]; do
    sleep 1
  done

  # Label Nodes
  label_vms

  # Install Addons
  install_addons
  install_addons_optional

  get_dashboard_secret

  echo " "
  echo "export KUBECONFIG=/mnt/storage/vm/${PREFIX}/${PREFIX}.yaml"
  echo "${PREFIX} k3s Install Complete!"
}

monitor_okd_virt() {
  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  "${OKD}/openshift-install" agent wait-for bootstrap-complete --dir "${OKD}/okd/"
  "${OKD}/openshift-install" agent wait-for install-complete --dir "${OKD}/okd/"
}

delete_okd_virt() {
  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  # TODO, Automate Finding Which IPs to Remove
  ssh-keygen -R 10.103.10.101
  ssh-keygen -R 10.103.10.102
  ssh-keygen -R 10.103.10.103

  echo -e "\n\n${BLUE}Delete All Existing Data:${NC}"
  rm -rf \
    ${OKD}/oc \
    ${OKD}/kubectl \
    ${OKD}/openshift-install \
    ${OKD}/okd

  # "${HOME}/.cache/agent" \
  # ${OKD}/openshift-install-linux* \
  # ${OKD}/openshift-client-linux* \

  kubectl delete -f "${HOMELAB}/sandbox/kubevirt/okd/vm" --ignore-not-found
}

delete_okd_bm() {
  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  echo -e "\n\n${BLUE}Delete All Existing Data:${NC}"
  rm -rf \
    ${OKD}/oc \
    ${OKD}/kubectl \
    ${OKD}/openshift-install \
    ${OKD}/okd

  #     "${HOME}/.cache/agent" \
  # ${OKD}/openshift-install-linux* \
  # ${OKD}/openshift-client-linux* \
}

okd_bm_worker_shutdown() {
  kubectl patch machineset okd-4ww5p-worker-1 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 0}}'
  kubectl patch machineset okd-4ww5p-worker-2 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 0}}'
  kubectl patch machineset okd-4ww5p-worker-3 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 0}}'
}

okd_bm_worker_startup() {
  kubectl patch machineset okd-4ww5p-worker-1 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 1}}'
  kubectl patch machineset okd-4ww5p-worker-2 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 1}}'
  kubectl patch machineset okd-4ww5p-worker-3 -n openshift-machine-api --type='merge' -p '{"spec": {"replicas": 1}}'
}


install_okd_prep() {

  sudo mount -o remount,size=8G,noatime /tmp

  export XDG_CACHE_HOME="/tmp/cache"
  mkdir -p "${XDG_CACHE_HOME}"

  export AVP_TYPE=vault
  export AVP_AUTH_TYPE=token
  if [ -z "${VAULT_TOKEN}" ]; then
    export VAULT_TOKEN
    VAULT_TOKEN=$(vault login --tls-skip-verify -address="${URL}" -method=userpass -token-only username=arthur)
  fi

  if [ -z "${URL}" ]; then
    echo -n URL:
    read -r -s URL
    echo ""
  fi
  echo "${URL}"

  echo -e "\n\n${BLUE}Get Registry URL:${NC}"
  export REGISTRY
  REGISTRY=${REGISTRY:-registry.arthurvardevanyan.com}
  if [ -z "${REGISTRY}" ]; then
    echo -n REGISTRY:
    read -r -s REGISTRY
    echo ""
  fi
  echo "${REGISTRY}"

  echo -e "\n\n${BLUE}Download Dependencies:${NC}"
  export OKD_VERSION=${OKD_VERSION:-""}
  if [ -z "${OKD_VERSION}" ]; then
    export OKD_CHANNEL=${OKD_CHANNEL:-4-scos-stable}
    # https://github.com/JaimeMagiera/oct/blob/3968059ca79d9b60245aaff659533f6090c9a722/helpers/okd-query-releases.sh#L137
    OKD_VERSION=$(curl -s "https://amd64.origin.releases.ci.openshift.org/releasestream/${OKD_CHANNEL}" | grep "Accepted" -B 1 | awk 'sub(/.*release\/ */,""){f=1} f{if ( sub(/ *".*/,"") ) f=0; print}' | head -n 1)
  fi

  echo "${OKD_VERSION}"
  if [[ $OKD_VERSION == *"scos"* ]]; then
    export OKD_URL="quay.io/okd/scos-release:${OKD_VERSION}"
    export OKD_URL_CI="registry.ci.openshift.org/origin/release-scos:${OKD_VERSION}"
  else
    export OKD_URL="quay.io/openshift/okd:${OKD_VERSION}"
    export OKD_URL_CI="registry.ci.openshift.org/origin/release:${OKD_VERSION}"
  fi
  if [ ! -f "${OKD}/openshift-install-linux-${OKD_VERSION}.tar.gz" ]; then
    echo "Required tools not found. Downloading..."
    if ! oc adm release extract --tools "${OKD_URL}" --to="${OKD}/"; then
      echo -e "${BLUE}Trying CI Registry:${NC}"
      oc adm release extract --tools "${OKD_URL_CI}" --to="${OKD}/"
    fi
  else
    echo "Tools already present. Skipping download."
  fi

  tar xvzf "${OKD}"/openshift-install-linux-4* -C "${OKD}"
  tar xvzf "${OKD}"/openshift-client-linux-4* -C "${OKD}"
  mkdir -p "${OKD}/vm"

  echo -e "\n\n${BLUE}Create Config Files:${NC}"
  # Create okd directory of openshift-install files
  mkdir -p "${OKD}"/okd
  # Copy the install-config.yaml
  export INSTALL_CONFIG_DIR=${INSTALL_CONFIG_DIR:-"${HOMELAB}/okd/install-config.yaml"}
  cp "${INSTALL_CONFIG_DIR}" "${OKD}/okd/"

  PULL_SECRET=$(vault kv get -field=auth secret/docker | jq -c)
  SSH=$(cat "${HOME}"/.ssh/id_ed25519.pub)
  sed -i "s/<SSH>/${SSH}/g" "${OKD}/okd/install-config.yaml"
  sed -i "s/<URL>/${URL}/g" "${OKD}/okd/install-config.yaml"
  sed -i "s/<REGISTRY>/${REGISTRY}/g" "${OKD}/okd/install-config.yaml"
  sed -i "s/<CONTROL_PLANE>/${TF_VAR_control_plane_count:-${CONTROL_PLANE_COUNT}}/g" "${OKD}/okd/install-config.yaml"
  sed -i "s/<WORKERS>/${TF_VAR_worker_count:-${WORKER_COUNT}}/g" "${OKD}/okd/install-config.yaml"
  sed -i "s/<PULL_SECRET>/\'$(printf '%s\n' "${PULL_SECRET}'" | sed 's/[&/\]/\\&/g')/g" "${OKD}/okd/install-config.yaml"
  cp "${OKD}/okd/install-config.yaml" "${OKD}/okd/install-config_backup.yaml"

  # export OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_OS_IMAGE_OVERRIDE:-"https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/pre-release/latest/rhcos-live-iso.x86_64.iso"}
}

install_okd_virt() {

  delete_okd_virt

  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  export CONTROL_PLANE_COUNT
  export WORKER_COUNT
  CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:-3}
  WORKER_COUNT=${WORKER_COUNT:-0}

  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-virt.arthurvardevanyan.com}

  export INSTALL_CONFIG_DIR="${HOMELAB}/sandbox/kubevirt/okd/configs/install-config.yaml"

  install_okd_prep

  cp "${HOMELAB}/sandbox/kubevirt/okd/configs/agent-config.yaml" "${OKD}/okd/"
  cp "${HOMELAB}/sandbox/kubevirt/okd/configs/containerfile" "${OKD}/okd/containerfile"

  "${OKD}/openshift-install" agent create cluster-manifests --dir "${OKD}/okd/"

  mkdir -p "${OKD}/okd/openshift"
  cp "${HOMELAB}/sandbox/kubevirt/okd/configs/ovn.yaml" "${OKD}/okd/openshift/cluster-network-03-config.yml"
  cp "${HOMELAB}/sandbox/kubevirt/okd/configs/boot-disk.yaml" "${OKD}/okd/openshift/boot-disk.yaml"
  cp "${HOMELAB}/sandbox/kubevirt/okd/configs/secondary-disk.yaml" "${OKD}/okd/openshift/secondary-disk.yaml"

  "${OKD}/openshift-install" agent create image --dir "${OKD}/okd/"

  podman build -f "${OKD}/okd/containerfile" -t "${REGISTRY}/homelab/okd-virt:latest"
  podman push "${REGISTRY}/homelab/okd-virt:latest"
  podman rmi -f "${REGISTRY}/homelab/okd-virt:latest"

  kubectl apply -f "${HOMELAB}/sandbox/kubevirt/okd/vm"

  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  kubectl config set-cluster okd --insecure-skip-tls-verify=true
  "${OKD}/openshift-install" agent wait-for bootstrap-complete --dir "${OKD}/okd/"
  # "${OKD}/oc" apply -f "${HOMELAB}/okd/okd-configuration/overlays/sandbox/ingress-controller.yaml"
  "${OKD}/openshift-install" agent wait-for install-complete --dir "${OKD}/okd/"

  kubectl label node sandbox-1 topology.kubernetes.io/zone=1 --overwrite
  kubectl label node sandbox-2 topology.kubernetes.io/zone=2 --overwrite
  kubectl label node sandbox-3 topology.kubernetes.io/zone=3 --overwrite
}

install_okd_sno() {

  delete_okd_bm
  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  export CONTROL_PLANE_COUNT
  export WORKER_COUNT
  CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:-1}
  WORKER_COUNT=${WORKER_COUNT:-0}

  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-sno.arthurvardevanyan.com}
  install_okd_prep

  cp "${HOMELAB}/sandbox/sno/agent-config.yaml" "${OKD}/okd/"

  "${OKD}/openshift-install" agent create cluster-manifests --dir "${OKD}/okd/"

  "${OKD}/openshift-install" agent create image --dir "${OKD}/okd/"

  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  "${OKD}/openshift-install" agent wait-for bootstrap-complete --dir "${OKD}/okd/"
  # "${OKD}/oc" apply -f "${HOMELAB}/okd/okd-configuration/overlays/sandbox/ingress-controller.yaml"
  "${OKD}/openshift-install" agent wait-for install-complete --dir "${OKD}/okd/"
}

install_okd_bm() {

  delete_okd_bm
  export HOMELAB="${PWD}"
  export OKD=/tmp/okd

  export CONTROL_PLANE_COUNT
  export WORKER_COUNT
  CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:-3}
  WORKER_COUNT=${WORKER_COUNT:-0}

  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-homelab.arthurvardevanyan.com}
  install_okd_prep

  cp "${HOMELAB}/okd/agent-config.yaml" "${OKD}/okd/"

  "${OKD}/openshift-install" agent create cluster-manifests --dir "${OKD}/okd/"

  mkdir -p "${OKD}/okd/openshift"
  cp "${HOMELAB}/okd/ovn.yaml" "${OKD}/okd/openshift/cluster-network-03-config.yml"
  cp "${HOMELAB}/okd/disks/boot-disk.yaml" "${OKD}/okd/openshift/boot-disk.yaml"
  cp "${HOMELAB}/okd/disks/secondary-disk.yaml" "${OKD}/okd/openshift/secondary-disk.yaml"

  "${OKD}/openshift-install" agent create image --dir "${OKD}/okd/"

  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  "${OKD}/openshift-install" agent wait-for bootstrap-complete --dir "${OKD}/okd/"
  # "${OKD}/oc" apply -f "${HOMELAB}/okd/okd-configuration/overlays/sandbox/ingress-controller.yaml"
  "${OKD}/openshift-install" agent wait-for install-complete --dir "${OKD}/okd/"

  kubectl label node server-1 topology.kubernetes.io/zone=1 --overwrite
  kubectl label node server-2 topology.kubernetes.io/zone=2 --overwrite
  kubectl label node server-3 topology.kubernetes.io/zone=3 --overwrite
  kubectl label node worker-1 topology.kubernetes.io/zone=1 --overwrite
  kubectl label node worker-2 topology.kubernetes.io/zone=2 --overwrite
  kubectl label node worker-3 topology.kubernetes.io/zone=3 --overwrite
}

delete_okd() {
  export HOME=/home/arthur
  export HOMELAB="${PWD}"
  export OKD=/mnt/storage/okd

  echo -e "\n\n${BLUE}Delete OKD Install:${NC}"

  echo -e "\n\n${BLUE}Delete Bootstrap:${NC}"
  cd "${HOMELAB}/terraform/sandbox/cluster"
  terraform init
  export TF_VAR_base_volume_id
  TF_VAR_base_volume_id=$(terraform output -raw base_volume_id)
  export TF_VAR_pool
  TF_VAR_pool=$(terraform output -raw pool)
  cd "${HOMELAB}/terraform/sandbox/bootstrap"
  terraform init
  terraform destroy -auto-approve

  echo -e "\n\n${BLUE}Delete Workers:${NC}"
  cd "${HOMELAB}/terraform/sandbox/workers"
  terraform init
  terraform destroy -auto-approve

  echo -e "\n\n${BLUE}Delete libvirt and Masters:${NC}"
  cd "${HOMELAB}/terraform/sandbox/cluster"
  terraform destroy -auto-approve

  if swapon --show | grep -q "${SWAP_PATH}"; then
    swapoff /home/swapfile.img
  fi

  echo -e "\n\n${BLUE}Delete All Existing Data:${NC}"
  rm -rf \
    "${OKD}"/openshift-install-linux* \
    "${OKD}"/openshift-client-linux* \
    "${OKD}"/oc \
    "${OKD}"/kubectl \
    "${OKD}"/openshift-install \
    "${OKD}"/fedora-coreos-* \
    "${OKD}"/*.qcow2 \
    "${OKD}"/okd \
    "${OKD}"

  cd "${HOMELAB}"
}

delete_okd_agent() {
  export HOME=/home/arthur
  export HOMELAB="${PWD}"
  export OKD=/mnt/storage/okd

  # TODO, Automate Finding Which IPs to Remove
  # TODO Stop Running as Sudo
  sudo -H -u arthur ssh-keygen -R 10.10.10.10
  sudo -H -u arthur ssh-keygen -R 10.10.10.11
  sudo -H -u arthur ssh-keygen -R 10.10.10.12

  echo -e "\n\n${BLUE}Delete Installation:${NC}"
  cd "${HOMELAB}/terraform/agent"
  terraform destroy -auto-approve

  echo -e "\n\n${BLUE}Delete All Existing Data:${NC}"
  rm -rf \
    "${OKD}"/openshift-install-linux* \
    "${OKD}"/openshift-client-linux* \
    "${OKD}"/oc \
    "${OKD}"/kubectl \
    "${OKD}"/openshift-install \
    "${OKD}"/fedora-coreos-* \
    "${OKD}"/*.qcow2 \
    "${OKD}"/okd

  if swapon --show | grep -q "${SWAP_PATH}"; then
    swapoff /home/swapfile.img
  fi

  cd "${HOMELAB}"
}

install_okd_libvirt_prep() {
  # https://blog.maumene.org/2020/11/18/OKD-or-OpenShit-in-one-box.html
  # ssh -i ~/.ssh/id_ed25519 core@10.10.10.10
  # journalctl -b -f -u kubelet.service -u ciro.service

  # TODO: Fix Permissions:
  # sudo vi /etc/libvirt/qemu.conf
  # user = "root"
  # group = "root"
  # sudo systemctl restart libvirtd
  export HOMELAB="${PWD}"
  export HOME=/home/arthur
  export OKD=/mnt/storage/okd
  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"

  export PREFIX=""
  export TF_VAR_control_plane_count=3

  # Expand Swap Size on Host Computer
  if ! test -f "${SWAP_PATH}"; then
    dd if=/dev/zero of="${SWAP_PATH}" bs=45056 count=1M
    mkswap "${SWAP_PATH}"
  fi

  if ! (swapon --show | grep -q "${SWAP_PATH}"); then
    swapon "${SWAP_PATH}"
  fi

  systemctl start haproxy
  systemctl stop firewalld
}

install_okd() {
  # Delete Cluster If Exists
  delete_okd
  export TF_VAR_worker_count=4
  install_okd_libvirt_prep
  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-sandbox.arthurvardevanyan.com}
  install_okd_prep

  # Create the ignition files
  "${OKD}/openshift-install" create ignition-configs --dir="${OKD}/okd"

  chown -R arthur:arthur ${OKD}
  chmod 777 -R ${OKD}

  echo -e "\n\n${BLUE}Start OKD Install:${NC}"
  echo -e "\n\n${BLUE}Setup libvirt and Masters:${NC}"
  cd "${HOMELAB}/terraform/sandbox/cluster"
  mkdir -p ${OKD}/terraform/cluster
  terraform init
  terraform apply -auto-approve
  export TF_VAR_base_volume_id
  TF_VAR_base_volume_id=$(terraform output -raw base_volume_id)
  export TF_VAR_pool
  TF_VAR_pool=$(terraform output -raw pool)

  echo -e "\n\n${BLUE}Initialize Bootstrap:${NC}"
  cd "${HOMELAB}/terraform/sandbox/bootstrap"
  mkdir -p ${OKD}/terraform/bootstrap
  terraform init
  terraform apply -auto-approve

  echo -e "\n\n${BLUE}Waiting For Bootstrap:${NC}"
  ${OKD}/openshift-install --dir=${OKD}/okd wait-for bootstrap-complete --log-level debug

  echo -e "\n\n${BLUE}Destroy Bootstrap:${NC}"
  cd "${HOMELAB}/terraform/sandbox/bootstrap"
  mkdir -p ${OKD}/terraform/bootstrap
  terraform destroy -auto-approve

  echo -e "\n\n${BLUE}Initialize Workers:${NC}"
  cd "${HOMELAB}/terraform/sandbox/workers"
  mkdir -p ${OKD}/terraform/workers
  terraform init
  terraform apply -auto-approve

  echo -e "\n\n${BLUE}Wait for Install To Complete:${NC}"
  #${OKD}/oc apply -f "${HOMELAB}/okd/okd-configuration/overlays/sandbox/ingress-controller.yaml"
  ${OKD}/openshift-install --dir=${OKD}/okd wait-for install-complete --log-level debug

  ${OKD}/oc apply -f "${HOMELAB}/okd/okd-configuration/base/operator-hub.yaml"
  ${OKD}/oc apply -f "${HOMELAB}/okd/okd-configuration/base/operators"

  echo -e "\n\n${BLUE}Setup Image Mirroring:${NC}"
  #sed 's/AllowContactingSource/NeverContactSource/' "${HOMELAB}"/okd/okd-configuration/base/image-mirror-set.yaml | kubectl apply -f -
  kubectl apply -f "${HOMELAB}"/okd/okd-configuration/base/image-mirror-set.yaml

  echo -e "\n\n${BLUE}Install Complete:${NC}"
  echo "export KUBECONFIG=${OKD}/okd/auth/kubeconfig"
  echo "Kubeadmin Password: $(cat ${OKD}/okd/auth/kubeadmin-password)"

  #single_server
}

install_okd_agent() {
  # Delete Cluster If Exists
  delete_okd_agent
  export TF_VAR_worker_count=0
  install_okd_libvirt_prep

  echo -e "\n\n${BLUE}Get URL:${NC}"
  export URL
  URL=${URL:-sandbox.arthurvardevanyan.com}
  install_okd_prep

  cp "${HOMELAB}/sandbox/libvirt/configs/agent-config.yaml" "${OKD}/okd/"
  "${OKD}/openshift-install" agent create cluster-manifests --dir "${OKD}/okd/"
  "${OKD}/openshift-install" agent create image --dir "${OKD}/okd/"

  chown -R arthur:arthur ${OKD}
  chmod 777 -R ${OKD}

  echo -e "\n\n${BLUE}Start OKD Install:${NC}"
  echo -e "\n\n${BLUE}Setup libvirt and Masters:${NC}"
  cd "${HOMELAB}/terraform/agent"
  mkdir -p ${OKD}/terraform/agent
  terraform init
  terraform apply -auto-approve

  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  "${OKD}/openshift-install" agent wait-for bootstrap-complete --dir "${OKD}/okd/"
  # "${OKD}/oc" apply -f "${HOMELAB}/okd/okd-configuration/overlays/sandbox/ingress-controller.yaml"
  "${OKD}/openshift-install" agent wait-for install-complete --dir "${OKD}/okd/"
}

single_server() {
  echo -e "\n\n${BLUE}Single Server Resource Adjustments:${NC}"
  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  "${OKD}/oc" scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator
  "${OKD}/oc" scale --replicas=1 deployment.apps/console -n openshift-console
  "${OKD}/oc" scale --replicas=1 deployment.apps/downloads -n openshift-console
  "${OKD}/oc" scale --replicas=1 deployment.apps/oauth-openshift -n openshift-authentication
  "${OKD}/oc" scale --replicas=1 deployment.apps/packageserver -n openshift-operator-lifecycle-manager

  "${OKD}/oc" scale --replicas=1 deployment.apps/prometheus-adapter -n openshift-monitoring
  "${OKD}/oc" scale --replicas=1 deployment.apps/thanos-querier -n openshift-monitoring
  "${OKD}/oc" scale --replicas=1 statefulset.apps/prometheus-k8s -n openshift-monitoring
  "${OKD}/oc" scale --replicas=1 statefulset.apps/alertmanager-main -n openshift-monitoring
}

install_addons_okd_virt() {
  # Tweak Settings from Physical HomeLab
  export OKD=/tmp/okd
  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  export HOMELAB="${PWD}"
  kubectl config set-cluster okd --insecure-skip-tls-verify=true

  echo -e "\n${BLUE}Installing Cluster Addons:${NC}"
  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-virt.arthurvardevanyan.com}
  if [ -z "${URL}" ]; then
    echo -n URL:
    read -r -s URL
    echo ""
  fi
  echo "${URL}"

  export AVP_TYPE=vault
  export AVP_AUTH_TYPE=token
  if [ -z "${VAULT_TOKEN}" ]; then
    export VAULT_TOKEN
    VAULT_TOKEN=$(vault login --tls-skip-verify -address="${URL}" -method=userpass -token-only username=arthur)
  fi

  kubectl config set-cluster okd --insecure-skip-tls-verify=true

  kubectl label node sandbox-1 topology.kubernetes.io/zone=1 --overwrite
  kubectl label node sandbox-2 topology.kubernetes.io/zone=2 --overwrite
  kubectl label node sandbox-3 topology.kubernetes.io/zone=3 --overwrite

  echo -e "\n${BLUE}Pull Secret:${NC}"
  argocd-vault-plugin generate "${HOMELAB}"/okd/okd-configuration/base/pull-secret.yaml | kubectl apply -f -
  sleep 30s
  while [ "$(kubectl get mcp master -o yaml | yq '.status.conditions[] | select(.type == "Updating") | .status')" == "True" ]; do
    echo "Waiting for MCPs"
    sleep 30s
  done
  oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/master
  echo -e "\n${BLUE}OperatorHub:${NC}"
  kubectl apply -f "${HOMELAB}"/okd/okd-configuration/base/operator-hub.yaml

  sleep 30s
  echo -e "\n${BLUE}Waiting for MarketPlace Pods to Boot:${NC}"
  while [ "$(kubectl get pods -n openshift-marketplace | grep -v "Completed" | grep -cv Running)" -ne 1 ]; do
    sleep 1
  done

  echo -e "\n${BLUE}Kyverno:${NC}"
  kubectl kustomize "${HOMELAB}"/kubernetes/kyverno/overlays/okd/ | argocd-vault-plugin generate - | kubectl apply -f - --server-side

  echo -e "\n${BLUE}Cert Manager:${NC}"
  # shellcheck disable=SC2317
  cert_manager() {
    kubectl kustomize "${HOMELAB}"/kubernetes/cert-manager/overlays/okd-sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }
  retry 5 cert_manager

  echo -e "\n${BLUE}Nmstate:${NC}"
  # shellcheck disable=SC2317
  nmstate() {
    kubectl create ns openshift-nmstate
    kubectl kustomize "${HOMELAB}"/kubernetes/nmstate/overlays/sandbox | kubectl apply -f -
  }
  retry 5 nmstate

  echo -e "\n${BLUE}OKD Configuration:${NC}"
  # shellcheck disable=SC2317
  okd_configuration() {
    kubectl kustomize "${HOMELAB}"/okd/okd-configuration/overlays/sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }

  kubectl kustomize kubernetes/nmstate/overlays/sandbox | kubectl apply -f -

  retry 5 okd_configuration

  cert_check() {

    # shellcheck disable=SC2317
    while [ "$(kubectl get certificate -n openshift-config api-certificate -o yaml | yq '.status.conditions[] | select(.type == "Ready") | .status')" == "False" ]; do
      echo "Waiting for API Certificate to Generate"
      sleep 30
    done

    # shellcheck disable=SC2317
    while [ "$(kubectl get certificate -n openshift-ingress ingress-certificate -o yaml | yq '.status.conditions[] | select(.type == "Ready") | .status')" == "False" ]; do
      echo "Waiting for Ingress Certificate to Generate"
      sleep 30
    done
  }

  sleep 30

  retry 5 cert_check

  sleep 120

  oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/master
  oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/worker

  echo -e "\n\n${BLUE}Addons Installed!${NC}"
}

install_addons_okd() {
  # Tweak Settings from Physical HomeLab
  export OKD=/mnt/storage/okd
  export KUBECONFIG="${OKD}/okd/auth/kubeconfig"
  export HOMELAB="${PWD}"

  echo -e "\n${BLUE}Installing Cluster Addons:${NC}"
  echo -e "\n\n${BLUE}Get URL:${NC}"
  URL=${URL:-arthurvardevanyan.com}
  if [ -z "${URL}" ]; then
    echo -n URL:
    read -r -s URL
    echo ""
  fi
  echo "${URL}"

  export AVP_TYPE=vault
  export AVP_AUTH_TYPE=token
  if [ -z "${VAULT_TOKEN}" ]; then
    export VAULT_TOKEN
    VAULT_TOKEN=$(vault login --tls-skip-verify -address="${URL}" -method=userpass -token-only username=arthur)
  fi

  sleep 15s
  while [ "$(kubectl get mcp worker -o yaml | yq '.status.conditions[] | select(.type == "Updating") | .status')" == "True" ]; do
    echo "Waiting for MCPs"
    sleep 30s
  done

  oc debug node/worker-0 -t -- chroot /host sudo mkfs.ext4 -L longhorn /dev/vdb
  oc debug node/worker-1 -t -- chroot /host sudo mkfs.ext4 -L longhorn /dev/vdb
  oc debug node/worker-2 -t -- chroot /host sudo mkfs.ext4 -L longhorn /dev/vdb
  oc debug node/worker-3 -t -- chroot /host sudo mkfs.ext4 -L longhorn /dev/vdb || true

  kubectl label node worker-0 topology.kubernetes.io/zone="even" --overwrite
  kubectl label node worker-1 topology.kubernetes.io/zone="odd" --overwrite
  kubectl label node worker-2 topology.kubernetes.io/zone="even" --overwrite
  kubectl label node worker-3 topology.kubernetes.io/zone="odd" --overwrite || true

  kubectl annotate node "worker-0" node.longhorn.io/default-disks-config='[{"path":"/var/mnt/longhorn","allowScheduling":true}]' --overwrite
  kubectl annotate node "worker-1" node.longhorn.io/default-disks-config='[{"path":"/var/mnt/longhorn","allowScheduling":true}]' --overwrite
  kubectl annotate node "worker-2" node.longhorn.io/default-disks-config='[{"path":"/var/mnt/longhorn","allowScheduling":true}]' --overwrite
  kubectl annotate node "worker-3" node.longhorn.io/default-disks-config='[{"path":"/var/mnt/longhorn","allowScheduling":true}]' --overwrite || true

  kubectl label node "worker-0" node.longhorn.io/create-default-disk=config --overwrite
  kubectl label node "worker-1" node.longhorn.io/create-default-disk=config --overwrite
  kubectl label node "worker-2" node.longhorn.io/create-default-disk=config --overwrite
  kubectl label node "worker-3" node.longhorn.io/create-default-disk=config --overwrite || true

  kubectl label node "worker-0" node-role.kubernetes.io/infra="" --overwrite
  kubectl label node "worker-1" node-role.kubernetes.io/infra="" --overwrite
  kubectl label node "worker-2" node-role.kubernetes.io/infra="" --overwrite
  kubectl label node "worker-3" node-role.kubernetes.io/infra="" --overwrite || true

  kubectl apply -f "${HOMELAB}"/okd/okd-configuration/base/mcp.yaml
  yq '.spec.config.systemd.units[1].enabled=false' "${HOMELAB}"/okd/okd-configuration/overlays/sandbox/longhorn-mc.yaml | kubectl apply -f -

  sleep 15s
  while [ "$(kubectl get mcp infra -o yaml | yq '.status.conditions[] | select(.type == "Updating") | .status')" == "True" ]; do
    echo "Waiting for MCPs"
    sleep 30s
  done

  echo -e "\n${BLUE}Longhorn:${NC}"
  # shellcheck disable=SC2317
  longhorn() {
    kubectl kustomize "${HOMELAB}"/kubernetes/longhorn/overlays/okd-sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }
  retry 5 longhorn

  echo -e "\n${BLUE}Waiting for Longhorn to Boot:${NC}"
  while [ "$(kubectl get pods -n longhorn-system | grep -cv Running)" -ne 1 ]; do
    sleep 1
  done

  echo -e "\n${BLUE}OKD Monitoring:${NC}"
  # shellcheck disable=SC2317
  okd_monitoring() {
    kubectl kustomize "${HOMELAB}"/okd/openshift-monitoring/overlays/sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }
  retry 5 okd_monitoring

  echo -e "\n${BLUE}Cert Manager:${NC}"
  # shellcheck disable=SC2317
  cert_manager() {
    kubectl kustomize "${HOMELAB}"/kubernetes/cert-manager/overlays/okd-sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }
  retry 5 cert_manager

  echo -e "\n${BLUE}OKD Configuration:${NC}"
  # shellcheck disable=SC2317
  okd_configuration() {
    kubectl kustomize "${HOMELAB}"/okd/okd-configuration/overlays/sandbox | argocd-vault-plugin generate - | kubectl apply -f -
  }
  retry 5 okd_configuration

  oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/master
  oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/worker
  oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/infra

  cert_check() {

    # shellcheck disable=SC2317
    while [ "$(kubectl get certificate -n openshift-config api-certificate -o yaml | yq '.status.conditions[] | select(.type == "Ready") | .status')" == "False" ]; do
      echo "Waiting for API Certificate to Generate"
      sleep 30
    done

    # shellcheck disable=SC2317
    while [ "$(kubectl get certificate -n openshift-ingress ingress-certificate -o yaml | yq '.status.conditions[] | select(.type == "Ready") | .status')" == "False" ]; do
      echo "Waiting for Ingress Certificate to Generate"
      sleep 30
    done
  }

  sleep 30

  retry 5 cert_check

  sleep 120

  oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/master
  oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/worker
  oc patch --type=merge --patch='{"spec":{"paused":false}}' machineconfigpool/infra

  echo -e "\n\n${BLUE}Addons Installed!${NC}"
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
