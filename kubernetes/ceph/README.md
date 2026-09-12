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

## Known Issues

### minio-go v7.0.98 / Ceph v20.2.4 SigV4 Signature Incompatibility

**Impact:** Post-upgrade OBC S3 "Access Denied" (403) errors on PUT operations.

**Root Cause:** `minio-go/v7.0.98` streaming signer excludes `Content-Type` from `SignedHeaders`, conflicting with Ceph's CVE-2026-54330 SigV4 hardening.

**Affected clients/buckets:**

- `thanos-chunk-store`
- `thanos-index-store`
- `thanos-delete-store`
- `netobserv`
- `openshift-logging`

**Working clients/buckets:**

- `thanos-compact/store/sidecar` (v7.0.93 — unaffected version)
- `open-webui` (Boto3/1.42.62 — uses different signing logic)
- `quay`
- `nextcloud`

**Related PRs:**

- <https://github.com/minio/minio-go/pull/2300> (issue)
- <https://github.com/minio/minio-go/pull/2301> (fix)
- <https://github.com/ceph/ceph/pull/71364> (RGW flexibility fix)

**Resolution:**

- No server-side RGW config option exists to relax SigV4 enforcement for general clients.
- Upstream operators cannot be controlled/updated (OpenShift operators).
- **Pending AES requirement:** Upgrade affected clients to a fixed version of `minio-go` that includes the signature fix, or migrate to an SDK version that properly includes `Content-Type` in signed headers.

### CephX Key Rotation (CVE-2025-30156)

Ceph announced security vulnerability CVE-2025-30156 impacting all Ceph clusters. The existing AES service tickets do not effectively implement integrity checks and can have their permissions modified without detection.

**Resolution:**

- Upgrade to Rook v1.20.6+ (or v1.19.10+) and Ceph v20.2.4+ (or v19.2.6+)
- Initiate key rotation by setting `keyRotationPolicy: KeyGeneration` and incrementing `keyGeneration` in the CephCluster CR
- Core daemon keys (mon, mgr, osd, mds) must migrate to AES256K to resolve the vulnerability
- CSI, CephClient, and RBD-mirror peer keys may remain on `aes` type during transition if host kernels do not support AES256K (requires Linux kernel 7.0+)
- Reference: <https://rook.io/docs/rook/latest/Storage-Configuration/Advanced/cephx-key-rotation/>

**Current Status:**

- [ ] Verify current Rook and Ceph versions meet requirements
- [ ] Apply key rotation patch to CephCluster CR if needed
- [ ] Mute remaining health warnings if applicable:

  ```yaml
  healthCheck:
    muteHealthWarning:
      AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE:
        policy: mute
      AUTH_INSECURE_CLIENT_KEY_TYPE:
        policy: mute
      AUTH_INSECURE_KEYS_ALLOWED:
        policy: mute
      AUTH_INSECURE_KEYS_CREATABLE:
        policy: mute
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
