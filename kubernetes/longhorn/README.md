# Longhorn

```bash
export OVERLAY=k3s
export OVERLAY=okd-sandbox
export OVERLAY=okd

kubectl kustomize kubernetes/longhorn/overlays/"${OVERLAY}" | argocd-vault-plugin generate - | kubectl apply -f -
```

## OKD Longhorn Secondary Disk Setup

```bash
# https://askubuntu.com/questions/144894/add-physical-disk-to-kvm-virtual-machine
sudo mkfs.ext4 -L longhorn /dev/nvme0n1
sudo mkfs.ext4 -L longhorn1 /dev/nvme1n1

# Sandbox
sudo mkfs.ext4 -L longhorn /dev/vdb
sudo mkfs.ext4 -L longhorn1 /dev/vdc

# Pre Machine Config (Sandbox)
sudo su
echo "/dev/vdb /var/mnt/longhorn auto nofail" > /etc/fstab
sudo reboot

export NODE=""
oc annotate node ${NODE} --overwrite node.longhorn.io/default-disks-config='[{"path":"/var/mnt/longhorn","allowScheduling":true}]'
oc label node ${NODE} node.longhorn.io/create-default-disk=config

# Infra
kubectl taint node ${NODE} node-role.kubernetes.io/infra:NoSchedule
kubectl label node ${NODE} node-role.kubernetes.io/infra=""

```

## OKD Upgrade

```bash
bash main.bash stateful_workload_stop
kubectl delete pdb -n longhorn-system --all
bash main.bash stateful_workload_start
```

## REF

- <https://github.com/longhorn/longhorn/pull/5004>
- <https://longhorn.io/kb/tip-only-use-storage-on-a-set-of-nodes/>
- <https://longhorn.io/blog/longhorn-v1.1.0/.>
- <https://longhorn.io/docs/1.2.2/deploy/uninstall/>
- <https://github.com/longhorn/longhorn/wiki/Roadmap>
- <https://github.com/longhorn/longhorn/issues/1831>
- <https://github.com/longhorn/longhorn/issues/1631>
- <https://github.com/longhorn/longhorn/issues/1757>
- <https://github.com/longhorn/longhorn/pull/2909>
- <https://github.com/longhorn/longhorn>
- <https://longhorn.io/kb/troubleshooting-open-iscsi-on-rhel/>
- <https://longhorn.io/kb/troubleshooting-volumes-stuck-in-attach-detach-loop-when-using-longhorn-on-okd/>
- <https://longhorn.io/docs/1.4.1/advanced-resources/default-disk-and-node-config/>
