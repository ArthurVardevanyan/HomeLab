# Sandbox

## Virtual Sandbox

```bash
# Terminal 1
# Generate Preseed Config Password and Startup Temporary Web Server
bash kvm_k3s.bash preseed_server

# Terminal 2
# Enter Password Defined with Hash in Pre Seed Config
mkdir -p notes time bash kvm_k3s.bash install_cluster > notes/install.log

# KubeConfig
export KUBECONFIG=${HOME}/vm/sk3s/sk3s.yaml

# Dashboard Secret
bash main.bash get_dashboard_secret
```

## KVM Sandbox Terraform

TF Provider

- <https://github.com/dmacvicar/terraform-provider-libvirt>
- <https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs>

OpenShift Terraform Example

- <https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md>
- <https://github.com/openshift/installer/tree/master/data/data/libvirt/bootstrap>

Permission Denied Issue

- <https://github.com/jedi4ever/veewee/issues/996#issuecomment-497976612>

#### KVM Config Dump

```bash
scp ./* arthur@10.102.2.117:/home/arthur/Downloads

sudo virsh dumpxml infra-1 > infra-1.xml
sudo virsh dumpxml server-1 > server-1.xml
sudo virsh dumpxml worker-1 > worker-1.xml
sudo virsh dumpxml worker-4 > worker-4.xml

sudo virsh dumpxml infra-2 > infra-2.xml
sudo virsh dumpxml server-2 > server-2.xml
sudo virsh dumpxml worker-2 > worker-2.xml
sudo virsh dumpxml worker-5 > worker-5.xml

sudo virsh dumpxml infra-3 > infra-3.xml
sudo virsh dumpxml server-3 > server-3.xml
sudo virsh dumpxml worker-3 > worker-3.xml
sudo virsh dumpxml worker-6 > worker-6.xml
```

#### OKD Host Disk Expansion

```bash
# KVM
sudo qemu-img resize X.raw +XG

# Node
# https://access.redhat.com/discussions/6230831#comment-2163981
sudo su
growpart /dev/vda 4
lsblk
sudo su -
unshare --mount
mount -o remount,rw /sysroot
xfs_growfs /sysroot
df -h | grep vda
```

#### OKD Host Bad Block Recovery

```bash
dd if=/mnt/source/source.raw  of=/mnt/destination/destination.raw bs=4k conv=noerror,sync
```

#### k3s Install

```bash
export K3S_TOKEN="k3s"
export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi"

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init --disable traefik ${RESERVED}" \
  INSTALL_K3S_CHANNEL=v1.28 sh -
```

## Database

### MariaDB

```sql
CREATE USER 'arthur'@'10.0.0.X' IDENTIFIED BY 'arthur';
GRANT ALL PRIVILEGES ON *.* TO `arthur`@`10.0.0.X`;

FLUSH PRIVILEGES;

# % for everything
CREATE USER 'spotifyTest'@'10.42.0.%' IDENTIFIED BY 'spotifyTest';
GRANT ALL PRIVILEGES ON spotifyTest.* TO `spotifyTest`@`10.42.0.%`;

# View Only Access
GRANT SELECT, LOCK TABLES, SHOW VIEW ON *.* TO 'backup'@'10.42.0.1' IDENTIFIED BY 'backup';
```

### Postgres

```psql
psql -h localhost -d quay -U quay
\c quay
CREATE EXTENSION pg_trgm;
```

## Quay

```bash
kubectl scale --replicas=1 -n quay deployment/quay-operator-tng

kubectl scale --replicas=0 -n quay deployment/quay-operator-tng
kubectl patch -n quay deployment/quay-quay-app --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {"limits": {"cpu": "1000m","memory": "8Gi", "ephemeral-storage": "2Gi"},"requests": {"cpu": "150m","memory": "4Gi", "ephemeral-storage": "1Gi"}}}]'
kubectl patch -n quay deployment/quay-clair-app --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {"limits": {"cpu": "500m","memory": "2.5Gi", "ephemeral-storage": "3Gi"},"requests": {"cpu": "150m","memory": "756Mi", "ephemeral-storage": "1Gi"}}}]'
kubectl patch -n quay deployment/quay-quay-mirror --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {"limits": {"cpu": "250m","memory": "512Mi"},"requests": {"cpu": "50m","memory": "256Mi"}}}]'
```

## Tekton

```bash
kubectl delete replicaSet -n openshift-pipelines --all

# Image Build
tkn -n homelab pipeline start image-build -s pipeline \
  --param="git-url=https://git.arthurvardevanyan.com/ArthurVardevanyan/HomeLab" \
  --param="IMAGE=registry.arthurvardevanyan.com/homelab/toolbox:not_latest" \
  --param="git-commit=$(git log --format=oneline | cut -d ' ' -f 1 | head -n 1)" \
  --param="DOCKERFILE=./containers/toolbox/containerfile" \
  --workspace=name=data,volumeClaimTemplateFile=tekton/base/pvc.yaml \
  --showlog

tkn -n homelab pipeline start image-build -s pipeline \
  --param="git-url=https://git.arthurvardevanyan.com/ArthurVardevanyan/HomeLab" \
  --param="IMAGE=registry.arthurvardevanyan.com/homelab/apache-php:$(date --utc '+%Y%m%d-%H%M')" \
  --param="git-commit=$(git log --format=oneline | cut -d ' ' -f 1 | head -n 1)" \
  --param="DOCKERFILE=./containers/apache-php/containerfile" \
  --workspace=name=data,volumeClaimTemplateFile=tekton/base/pvc.yaml \
  --showlog

# Ansible
tkn -n homelab pipeline start ansible -s pipeline \
  --workspace=name=data,volumeClaimTemplateFile=tekton/base/pvc.yaml \
  --param="git-url=https://git.arthurvardevanyan.com/ArthurVardevanyan/HomeLab" \
  --param="playbooks=desktop" \
  --param="git-name=ArthurVardevanyan/HomeLab" \
  --param="git-commit=$(git log --format=oneline | cut -d ' ' -f 1 | head -n 1)" \
  --showlog
```
