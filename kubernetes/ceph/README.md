# CEPH

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

ceph status
ceph osd status
ceph health detail

ceph osd crush rm-device-class  osd.0
ceph osd crush set-device-class nvme osd.0
ceph osd crush rm-device-class  osd.1
ceph osd crush set-device-class nvme osd.1
ceph osd crush rm-device-class  osd.2
ceph osd crush set-device-class nvme osd.2
ceph osd crush rm-device-class  osd.3
ceph osd crush set-device-class nvme osd.3
ceph osd crush rm-device-class  osd.4
ceph osd crush set-device-class nvme osd.4
ceph osd crush rm-device-class  osd.5
ceph osd crush set-device-class nvme osd.5

ceph osd destroy 2 --yes-i-really-mean-it
ceph auth del osd.2
ceph osd crush rm osd.2
ceph osd purge 2 --yes-i-really-mean-it

ceph mon remove d

ceph tell osd.\* injectargs --osd_max_backfills=32 --osd_recovery_max_active=64
ceph osd unset-group noout <NODE/OSD>
ceph crash archive-all

sudo rm -rf /var/lib/rook
sudo wipefs -a /dev/nvme0n1
sudo wipefs -a /dev/nvme1n1

sudo sgdisk --zap--all /dev/nvme0n1
sudo sgdisk --zap--all /dev/nvme1n1

sudo blkdiscard  /dev/nvme0n1
sudo blkdiscard /dev/nvme1n1

kubectl apply -f kubernetes/ceph/base/file
kubectl apply -f kubernetes/ceph/base/block
kubectl apply -f kubernetes/ceph/base/block-ci

kubectl delete -f kubernetes/ceph/base/file --ignore-not-found
kubectl delete -f kubernetes/ceph/base/block --ignore-not-found
kubectl delete -f kubernetes/ceph/base/block-ci --ignore-not-found

```

## Networking Test

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rook-ceph-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: rook-ceph-system
    namespace: rook-ceph
```

```bash
./notes/rook multus validation run -n rook-ceph --public-network "rook-ceph/ceph-public" --cluster-network "rook-ceph/ceph-cluster" # --host-check-only

./notes/rook multus validation cleanup --namespace rook-ceph
```

## Refs

- <https://rook.io/docs/rook/latest/Getting-Started/example-configurations/>
- <https://rook.io/docs/rook/latest/Troubleshooting/ceph-toolbox/#interactive-toolbox>
- <https://rook.io/docs/rook/latest-release/Storage-Configuration/Object-Storage-RGW/object-storage/#prerequisites>
- <https://rook.io/docs/rook/latest-release/Getting-Started/example-configurations/>
- <https://rook.io/docs/rook/latest-release/Getting-Started/example-configurations/#object-storage-buckets>
- <https://rook.io/docs/rook/latest/Storage-Configuration/Block-Storage-RBD/block-storage/>
- <https://rook.io/docs/rook/latest-release/Storage-Configuration/Block-Storage-RBD/block-storage/#provision-storage>
- <https://rook.io/docs/rook/latest/Getting-Started/quickstart/>
- <https://arpnetworks.com/blog/2019/06/28/how-to-update-the-device-class-on-a-ceph-osd.html>
- <https://access.redhat.com/documentation/en-us/red_hat_ceph_storage/4/html/troubleshooting_guide/troubleshooting-ceph-placement-groups>
- <https://access.redhat.com/solutions/6982727>
- <https://forum.proxmox.com/threads/health_warn-1-daemons-have-recently-crashed.63105/>
- <https://access.redhat.com/solutions/6067551>
