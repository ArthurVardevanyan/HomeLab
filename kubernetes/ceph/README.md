# CEPH

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

ceph status
ceph osd status
ceph health detail

ceph osd crush rm-device-class osd.0
ceph osd crush set-device-class nvme  osd.0

ceph osd destroy 0 --yes-i-really-mean-it
ceph auth del osd.0
ceph osd crush rm osd.0
ceph osd purge 0 --yes-i-really-mean-it

ceph mon remove j

ceph tell osd.\* injectargs --osd_max_backfills=32 --osd_recovery_max_active=64
ceph osd unset-group noout <NODE/OSD>
ceph crash archive-all
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
