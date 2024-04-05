# CEPH

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

ceph status
ceph osd status
ceph health detail

ceph osd crush rm-device-class osd.0 osd.1 osd.2 osd.3 osd.4 osd.5
ceph osd crush set-device-class nvme  osd.0 osd.1 osd.2 osd.3 osd.4 osd.5
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
