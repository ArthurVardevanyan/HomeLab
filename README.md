# HomeLab

HomeLab Server/Cluster, Virtual Sandbox Cluster, & Desktop Configuration

- Server: Debian Stable /w K3s & ZFS
- Desktop: Pop!_OS Latest

  - Manual Patches Applied

    - <https://github.com/ArthurVardevanyan/pop-shell>
    - <https://github.com/ArthurVardevanyan/pop-cosmic>

## Desktop

```bash
ansible-playbook -i ansible/inventory --ask-become-pass ansible/desktop.yaml --ask-pass

git merge --no-ff
scp -r /home/arthur/vm windowsBackup@10.0.0.3:/backup/WindowsBackup/vm
sudo sensors-detect
```

### Gnome

Manually Install Extensions from extensions.gnome.org

- gnome-shell-extension-netspeed
- gnome-shell-extension-places-menu
- gnome-shell-extension-transparentnotification
- gnome-shell-extension-tray-icons-reloaded

### Cura

Config files need to be applied manually.

```bash
machineConfigs/desktop/home/arthur/cura
```

## Virtual Sandbox

```bash
# Terminal 1
# Generate Preseed Config Password and Startup Temporary Webserver
bash kvm_k3s.bash preseed_server

# Terminal 2
# Enter Password Defined with Hash in Pre Seed Config
mkdir -p notes time bash kvm_k3s.bash install_cluster > notes/install.log

# KubeConfig
export KUBECONFIG=${HOME}/vm/sk3s/sk3s.yaml

# Dashboard Secret
bash kvm_k3s.bash get_dashboard_secret
```

## Server

### Kubernetes

<https://k3s.io/>

k3s Channel | Operating System
----------- | ----------------
v1.23       | Debian 11

**Machines:**

[CPU Benchmark](https://www.cpubenchmark.net/compare/Intel-i5-6600-vs-AMD-RX-427BB-vs-Intel-i3-2130-vs-AMD-GX-415GA-SOC/2594vs2496vs755vs2081)

Machine    | Model             | CPU      | CPU | Mem | Storage           | ZFS Storage
---------- | ----------------- | -------- | --- | --- | ----------------- | -------------
pfSense    | Hp t730           | RX-427BB | 4   | 4G  | 16G SSD           | N/A
Bare Metal | Hp t620           | GX-415GA | 4   | 6G  | 16G SSD & 16G USB | N/A
Infra KVM  | Hp ProDesk 400 G3 | i5-6600  | 4   | 16G | 240G SSD          | 2T ZFS Mirror
KVM        | Hp p7-1226s       | i3-2130  | 4   | 8G  | 240G SSD          | 1T ZFS Mirror

**ZFS Storage:**

Machine   | Use     | Dataset   | Size  | Dataset         | Size | Dataset       | Size
--------- | ------- | --------- | ----- | --------------- | ---- | ------------- | -----
Infra KVM | Primary | Nextcloud | 750GB | Longhorn Backup | 75GB | WindowsBackup | 750GB
KVM       | Backup  | Nextcloud | 750GB | Longhorn Backup | 75GB | N/A           | N/A

**Kubernetes Nodes:**

NAME         | ROLES          | IP         | Machine    | hCPU | vCPU | Mem   | Storage
------------ | -------------- | ---------- | ---------- | ---- | ---- | ----- | ------------
k3s-server-1 | cp,etcd,master | 10.0.0.5   | Bare Metal | 4    | N/A  | 6G    | LH SSD & USB
k3s-server-2 | cp,etcd,master | 10.0.0.102 | Infra KVM  | 4    | 2    | 1.75G | LH SSD
k3s-server-3 | cp,etcd,master | 10.0.0.103 | KVM        | 4    | 2    | 1.75G | N/A
k3s-worker-1 | infra,worker   | 10.0.0.111 | Infra KVM  | 4    | 4    | 10G   | LH SSD
k3s-worker-2 | worker         | 10.0.0.112 | KVM        | 4    | 4    | 4.25G | N/A

#### OKD Setup

```bash
sudo fdisk /dev/vdb
sudo mkfs.ext4 -F /dev/vdb1
sudo su
echo "/dev/vdb1 /mnt/storage auto nofail" > /etc/fstab
```

#### K3S Setup

```bash
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

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init  --tls-san 10.0.0.100 --tls-san k3s.<URL>.com ${RESERVED}"\
INSTALL_K3S_CHANNEL=v1.23 sh -

# Servers
export K3S_TOKEN=""
export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi"

curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="server --server https://10.0.0.100:6443 --disable traefik ${RESERVED}" \
K3S_URL=https://10.0.0.100:6443 INSTALL_K3S_CHANNEL=v1.23 sh -

# Agents/Workers
export K3S_TOKEN=""
export RESERVED="--kubelet-arg system-reserved=cpu=250m,memory=250Mi --kubelet-arg kube-reserved=cpu=250m,memory=250Mi"

curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="${RESERVED}" \
K3S_URL=https://10.0.0.100:6443 INSTALL_K3S_CHANNEL=v1.23 sh -
```

#### K3S Post Setup

```bash
# Label Nodes
bash kvm_k3s label_nodes

# Drain DaemonSets Temporarily off a Node
kubectl taint node k3s-server- node-role.kubernetes.io/control-plane:NoExecute
kubectl taint node k3s-server- node-role.kubernetes.io/control-plane:NoExecute-
```

#### K3S Commands

```bash
# Kubernetes Dashboard
# https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard
kubectl get secret -n kubernetes-dashboard \
$(kubectl get serviceaccount admin-user -n kubernetes-dashboard -o jsonpath="{.secrets[0].name}") \
-o jsonpath="{.data.token}" | base64 --decode

# Watch ALl Pods
watch kubectl get pods -A -o wide --sort-by=.metadata.creationTimestamp
# Delete Pods that Have a Restart
kubectl get pods -A | awk '$5>0' | awk '{print "kubectl delete pod -n " $1 " " $2}' | bash -
# Drain Node
kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data
# Vault
kubectl exec -it vault-0 -n vault -- vault operator unseal --tls-skip-verify
# Nextcloud
kubectl exec -it nextcloud-0 -n nextcloud -- runuser -u www-data -- php -f /var/www/html/occ
```

#### SSH Keyscan

```bash
export IP_LIST="3 4 5 17 102 103 111 112"

rm -f /tmp/ssh_keyscan.txt
for IP in $( echo "$IP_LIST" ); do
ssh-keyscan 10.0.0."${IP}" >> /tmp/ssh_keyscan.txt

done

echo "\n\n\nSSH Keyscan\n\n"
cat /tmp/ssh_keyscan.txt
```

#### K3S Image Cleanup

```bash
export IP_LIST="5 102 103 111 112"

for IP in $( echo "$IP_LIST" ); do
ssh -t arthur@10.0.0."${IP}" "sudo k3s crictl rmi --prune"
done
```

### GitLab

```bash
gitlab-ctl registry-garbage-collect
gitlab-ctl reconfigure
kubectl exec -it gitlab-0 -n gitlab -- bash

kubectl patch -n gitlab deployment/gitlab --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "gitlab/gitlab-ce:XX.X.X-ce.0"}]'
```

#### GitLab Vault Integration

```bash
# JWT Authentication
vault auth enable jwt
vault write auth/jwt/config jwks_url="<https://gitlab.<URL>/-/jwks>" bound_issuer="gitlab.<URL>"

# Policy
vault policy write homelab - <<EOF
path "secret/data/*" {
  capabilities = [ "read" ]
}
EOF

# Role
vault write auth/jwt/role/homelab - <<EOF
{
  "role_type": "jwt",
  "policies": ["homelab"],
  "token_explicit_max_ttl": 60,
  "user_claim": "user_email",
  "bound_claims": {
    "project_id": "XX",
    "ref": "production",
    "ref_type": "branch"
  }
}
EOF
```

#### GitLab Kubernetes Integration

```bash
# https://blog.ramon-gordillo.dev/2021/03/gitops-with-argocd-and-hashicorp-vault-on-kubernetes/
# https://cloud.redhat.com/blog/how-to-use-hashicorp-vault-and-argo-cd-for-gitops-on-openshift
# https://itnext.io/argocd-secret-management-with-argocd-vault-plugin-539f104aff05
vault auth enable kubernetes

token_reviewer_jwt=$(kubectl get secrets -n argocd -o jsonpath="{.items[?(@.metadata.annotations.kubernetes.io/service-account.name=='default')].data.token}" |base64 -d)

kubernetes_host=$(oc whoami --show-server)

# Pod With Service Account Token Mounted
kubectl cp -n argocd toolbox-0:/var/run/secrets/kubernetes.io/serviceaccount/..data/ca.crt /tmp/ca.crt

vault write auth/kubernetes/config \
   token_reviewer_jwt="${token_reviewer_jwt}" \
   kubernetes_host=${kubernetes_host} \
   kubernetes_ca_cert=@/tmp/ca.crt

vault write auth/kubernetes/role/argocd \
    bound_service_account_names=default \
    bound_service_account_namespaces=argocd \
    policies=argocd \
    ttl=1h

vault policy write argocd - <<EOF
path "secret/*" {
    capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

vault write auth/kubernetes/login role=argocd jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
```

## Database

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
