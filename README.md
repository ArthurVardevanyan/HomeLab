# HomeLab

HomeLab Server & Desktop Configuration

- Server: Debian Stable /w K3s & ZFS
- Desktop: Pop!_OS Latest

  - Manual Patches Applied

    - <https://github.com/ArthurVardevanyan/pop-shell>
    - <https://github.com/ArthurVardevanyan/pop-cosmic>

## Extra Commands & Notes

### Desktop

```bash
git merge --no-ff
scp -r /home/arthur/vmware windowsBackup@10.0.0.3:/backup/WindowsBackup/vmware
7z a -t7z -m0=lzma2 -mx=9 -mfb=128 -md=256m -ms=on FOLDER.7z FOLDER
sudo sensors-detect
```

#### Gnome

Manually Install Extensions from extensions.gnome.org

- gnome-shell-extension-netspeed
- gnome-shell-extension-places-menu
- gnome-shell-extension-transparentnotification
- gnome-shell-extension-tray-icons-reloaded

#### Cura

Config files need to be applied manually.

```bash
machineConfigs/home/arthur/cura
```

#### GWE

Database file needs to be restored manually.

### Server

#### Ansible

```bash
ansible-playbook -i ansible/inventory --ask-become-pass ansible/k3s.yaml --ask-pass --check
ansible-playbook -i ansible/inventory --ask-become-pass ansible/k3s-infra.yaml --ask-pass --check
ansible-playbook -i ansible/inventory --ask-become-pass ansible/desktop.yaml --ask-pass --check
```

#### ZFS

```bash
sudo zfs get compressratio
/usr/sbin/zfs send -i backup/File_Storage backup/File_Storage@20211201 | pv | ssh arthur@10.0.0.4 /usr/sbin/zfs receive -F backup/File_Storage
zfs send backup/File_Storage@20211101 | ssh arthur@10.0.0.4 zfs receive -F backup/File_Storage
```

Creating ZFS zvol for Timeshift

```bash
sudo zfs create -V 76.76G backup/Timeshift
sudo mkfs.ext4 /dev/zd0 # Note UUID
sudo mount /dev/zd0 /media/arthur/Timeshift
sudo umount /media/arthur/Timeshift
```

#### Kubernetes

<https://k3s.io/>

```bash
# Kubernetes Dashboard
# <https://upcloud.com/community/tutorials/deploy-kubernetes-dashboard>
kubectl get secret -n kubernetes-dashboard $(kubectl get serviceaccount admin-user -n kubernetes-dashboard -o jsonpath="{.secrets[0].name}") -o jsonpath="{.data.token}" | base64 --decode

# Watch ALl Pods
watch $(echo "kubectl get pods -A -o wide |  grep -v 'svclb' | sort -k8 -r")
# Delete Pods that Have a Restart
kubectl get pods -A | awk '$5>0' | awk '{print "kubectl delete pod -n " $1 " " $2}' | bash -
# Drain Node
kubectl drain k3s-worker --ignore-daemonsets --delete-emptydir-data

# Taint
kubectl taint node k3s-server node-role.kubernetes.io/master:NoSchedule

# Master Label
kubectl label nodes k3s-server node-type=master
kubectl label nodes k3s-infra node-type=master
kubectl label nodes k3s-worker node-type=master

# Role Label
kubectl label node k3s-infra node-role.kubernetes.io/infra=true
kubectl label node k3s-worker node-role.kubernetes.io/worker=true

# Longhorn Label
kubectl label node k3s-server node.longhorn.io/create-default-disk=true
kubectl label node k3s-infra node.longhorn.io/create-default-disk=true
kubectl label node k3s-worker node.longhorn.io/create-default-disk=true

# Servers
# Server
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init  --tls-san 10.0.0.100 --tls-san k3s.<URL>.com --disable traefik --flannel-iface=enp1s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=500m,memory=1Gi" INSTALL_K3S_CHANNEL=v1.22 sh -
# Infra
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --server https://:6443 --disable traefik --flannel-iface=enp1s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250,memory=1Gi" INSTALL_K3S_CHANNEL=v1.22 sh -
# Worker
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --server https://:6443 --disable traefik --flannel-iface=enp6s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=500m,memory=1Gi" INSTALL_K3S_CHANNEL=v1.22 sh -


# Agents
# Infra
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=enp1s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi" K3S_URL=https://10.0.0.5:6443 K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_CHANNEL=v1.22 sh -

# Worker
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=enp6s0 --kubelet-arg system-reserved=cpu=250m,memory=500Mi --kubelet-arg kube-reserved=cpu=250m,memory=500Mi" K3S_URL=https://10.0.0.5:6443 K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_CHANNEL=v1.22 sh -
```

#### Cockpit

```bash
sudo nano /etc/cockpit/ws-certs.d/1-my-cert.cert
```

#### Vault

```bash
kubectl exec -it $(kubectl -n vault get pod --selector='app=vault' -o custom-columns="-:metadata.name" --no-headers) -n vault -- vault operator unseal --tls-skip-verify
```

#### GitLab

```bash
gitlab-ctl registry-garbage-collect
gitlab-ctl reconfigure

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

#### Database

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
