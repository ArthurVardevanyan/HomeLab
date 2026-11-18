# CEPH

## Table of Contents

- [CEPH](#ceph)
  - [Table of Contents](#table-of-contents)
  - [Networking Test](#networking-test)
  - [Dashboard TLS](#dashboard-tls)
  - [Upgrades](#upgrades)
    - [Components tracked](#components-tracked)
    - [File classification](#file-classification)
    - [Checklist](#checklist)
  - [Known Issues](#known-issues)
    - [S3 `PUT` → `403 Forbidden` — Ceph v20.2.4 SigV4 Hardening (CVE-2026-54330)](#s3-put--403-forbidden--ceph-v2024-sigv4-hardening-cve-2026-54330)
    - [CephX Key Rotation (CVE-2025-30156)](#cephx-key-rotation-cve-2025-30156)
  - [Storage Class Image Features](#storage-class-image-features)
    - [CI StorageClass (`rook-ceph-block-virtualization-ci`)](#ci-storageclass-rook-ceph-block-virtualization-ci)
  - [Refs](#refs)

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

## Dashboard TLS

The dashboard serving certificate is issued by the OpenShift service-CA
operator and applied by Rook. A dedicated Service that only ArgoCD owns,
`rook-ceph-mgr-dashboard-cert`
(`base/rook-ceph-mgr-dashboard-cert-service.yaml`), carries the
`service.beta.openshift.io/serving-cert-secret-name` annotation and exists
only so the service-CA operator can maintain the
`rook-ceph-mgr-dashboard-tls` Secret (a cert for
`rook-ceph-mgr-dashboard-cert.rook-ceph.svc`). The annotation is not put on
the real `rook-ceph-mgr-dashboard` Service, because Rook owns and reconciles
that one and would drop foreign annotations — which would make the
service-CA operator delete the issued secret.

The CephCluster references the secret through
`spec.dashboard.sslCertificateRef`, so Rook configures the dashboard with it
and re-applies it automatically on rotation (Rook v1.21+) — no certificate
rotation CronJob is needed. This replaced the old
`ceph-dashboard-cert-rotate` CronJob, which copied the letsencrypt-issued
`rook-ceph-cert` into the mgr config-key every 6 hours, and was deleted.
The letsencrypt `rook-ceph-cert` Certificate itself stays: it is still the
TLS termination cert for the public route
(`base/gateway/listenerset.yaml`). The `BackendTLSPolicy` validates the
backend against the cert Service's DNS name above, with the service CA fed
into the `ca-bundle` by the trust-manager bundle in
`kubernetes/cert-manager`.

## Upgrades

Fast-track procedure for upgrading the Rook operator + Ceph daemons. Last run:
**v1.20.7 → v1.21.2** (2026-11-18), which also bumped the Ceph daemons
`v20.2.4 → v20.2.5-20261028`, ceph-csi-operator `v1.0.4 → v1.1.0`, and all 7
CSI sidecar images.

### Components tracked

| Component            | Image (digest-pinned)                          | Local file(s)                                 |
| -------------------- | ---------------------------------------------- | --------------------------------------------- |
| Rook Ceph operator   | `docker.io/rook/ceph:vX.Y.Z@sha256:...`        | `base/deployment.yaml`                        |
| Ceph daemons         | `quay.io/ceph/ceph:vA.B.C-YYYYMMDD@sha256:...` | `base/ceph-cluster.yaml`, `base/toolbox.yaml` |
| ceph-csi-operator    | `quay.io/cephcsi/ceph-csi-operator:vX@sha256`  | `base/csi/deployment.yaml`                    |
| 7 CSI sidecar images | tag-only upstream → **SHA-pinned locally**     | `base/csi/configmap.yaml`                     |

### File classification

**Wholesale-adopt from upstream** (rebuild, then apply the local transform):

- `base/crds.yaml` ← `deploy/examples/crds.yaml`
- `base/csi/rbac.yaml` ← CSI RBAC section of `deploy/examples/csi-operator.yaml`
- `base/csi/crds.yaml` ← CSI CRD section of `deploy/examples/csi-operator.yaml`
- `base/csi/network-policy.yaml` ← CSI NetworkPolicy from `deploy/examples/networkpolicy.yaml` (new in v1.21)

Local transform: `---` at the top of the file, strip trailing
`# namespace:operator` comments with `sed 's/ # namespace:operator$//'`,
ensure trailing newline, `prettier --write`, and expand any
kubebuilder-style `verbs: ["*"]` in unbound admin roles to an explicit verb
list (the repo's RBAC wildcard check rejects `*`).

**Delta-port** (heavily customized locally — cherry-pick only the upstream
changes, never replace the file):

- `base/deployment.yaml` — bump the operator image
- `base/configmap.yaml` — new/changed `ROOK_*` env vars (diff upstream
  `deploy/examples/common.yaml` against the old tag)
- `base/rbac-ceph-cluster.yaml` — new verbs/resources in `rook-ceph-global`
- `base/csi/deployment.yaml` — bump the csi-op image
- `base/csi/configmap.yaml` — bump the 7 sidecar tags and re-pin digests
- `base/ceph-cluster.yaml`, `base/toolbox.yaml` — Ceph daemon image
- `base/trim-override.yaml`
- `components/*/storage-class.yaml` — new CSI `parameters`, if any

### Checklist

1. **Fetch both tags:**
   `git clone --branch v<old> --depth 1 https://github.com/rook/rook` (and the
   same for the new tag), then diff `deploy/examples/` between the two checkouts.
   Both v1.20.x and v1.21.x ship the sample manifests there. New CSI sidecar
   tags are listed in `deploy/examples/images.txt`; note its Ceph daemon tag
   may lag the latest point release, so pick the desired
   `quay.io/ceph/ceph:vA.B.C-YYYYMMDD` tag from the [Ceph project](https://quay.io/organization/ceph)
   instead.
2. **Read the release notes** for both Rook and ceph-csi-operator for breaking
   changes and flipped defaults (e.g. v1.21 defaults
   `ROOK_REQUIRE_MSGR2`/`requireMsgr2` to `true` — we keep it `false`).
3. **Rebuild the wholesale-adopt files** from the new tag, apply the local
   transform, then verify the invariant: `diff` old-local vs new-local must be
   exactly the upstream delta (no formatting noise).
4. **Port the deltas** in the customized files.
5. **Re-pin all digests** with `skopeo inspect docker://<ref>` (use the
   top-level manifest-list digest) for rook/ceph, ceph/ceph, csi-op, and the
   7 sidecars in `base/csi/configmap.yaml`.
6. **StorageClass gotcha:** if the new CSI release adds `parameters` to the RBD
   StorageClasses, the fields are immutable — **delete them by hand before the
   ArgoCD sync** (the app uses server-side apply and would stall otherwise):

   ```bash
   kubectl -n rook-ceph get sc # confirm names
   kubectl delete sc rook-ceph-block rook-ceph-block-ci rook-ceph-block-virtualization rook-ceph-block-virtualization-ci
   ```

   ArgoCD recreates them on sync; existing PVCs/PVs are not affected.

7. **Validate locally** (see AGENTS.md for details):

   ```bash
   k8s-gitops-ci kustomize-fix -dir kubernetes/ceph
   k8s-gitops-ci test --app kubernetes/ceph --assume-openshift --disable-checks avp
   k8s-gitops-ci test --dirs "kubernetes/,tekton/,.tekton/,okd/" --assume-openshift --disable-checks avp
   ```

8. **Post-merge runbook** (in order):
   1. Delete the 4 RBD StorageClasses (only if new `parameters` were added).
   2. ArgoCD-sync the `ceph` app.
   3. Verify:
      - single operator version:
        `kubectl -n rook-ceph get deployment -l rook_cluster=rook-ceph` → one
        `rook-version=v<new>` per deployment
      - `kubectl -n rook-ceph get cephcluster rook-ceph` → `Ready`,
        `HEALTH_OK` (toolbox)
      - CSI: `kubectl get csidriver`, csi-op pod on the new image, sidecar pods
        on the new digests
      - the 4 RBD StorageClasses are recreated with the new `parameters`
      - if the RGW version changed, regression-test S3 `PUT` via thanos and
        nextcloud (see Known Issues)
   4. Expect brief mon/MDS flapping while the daemon image rolls — that is
      normal for a Ceph point-release upgrade.

## Known Issues

### S3 `PUT` → `403 Forbidden` — Ceph v20.2.4 SigV4 Hardening (CVE-2026-54330)

**Impact:** S3 `PUT` operations with a request body return `403 Forbidden`.
GET, HEAD, and LIST operations are unaffected.

**Root Cause:** `minio-go`'s streaming signer excludes `Content-Type` from
`SignedHeaders`, and some SDKs (e.g. `aws-sdk-php` used by Nextcloud) omit it
on certain paths. Ceph's CVE-2026-54330 hardening in v20.2.4 rejects requests
where `Content-Type` is present but not signed. Per the AWS SigV4 spec
`Content-Type` is an optional signature header — actual S3 accepts it unsigned.

**Affected clients/buckets:**

- `thanos-sidecar` (`minio-go/v7.0.93`) — chunk/index/delete-store PUTs
- `thanos-chunk-store`
- `thanos-index-store`
- `thanos-delete-store`
- `thanos-compact/store/sidecar`
- `netobserv` (S3 writes)
- `openshift-logging` (S3 writes)
- `nextcloud` (`aws-sdk-php`) — file uploads

**Working clients/buckets:**

- `open-webui` (Boto3 — uses different signing logic)
- `quay`

**Related PRs:**

- <https://github.com/minio/minio-go/pull/2300> (issue)
- <https://github.com/minio/minio-go/pull/2301> (fix)
- <https://github.com/ceph/ceph/pull/71364> (RGW Content-Type fix; merged to
  tentacle branch 2026-09-03, targets v20.2.5)

**Resolution:**

- **Applied (2026-10-01):** set `rgw_sigv4_insecure = true` in
  `kubernetes/ceph/base/trim-override.yaml`. This restores pre-CVE lenient
  behavior and immediately fixes all affected S3 clients.

  > **Security note:** this disables the CVE-2026-54330 SigV4 hardening,
  > including acceptance of unsigned `x-amz-*` headers. The RGW service is
  > ClusterIP-only (no Route/Ingress), so exposure is limited to cluster-internal
  > attackers. Acceptable for a homelab.

- **Resolved (2026-11-18):** upgraded to Ceph `v20.2.5-20261028` alongside
  Rook v1.21.2 (see [Upgrades](#upgrades)) and removed the
  `rgw_sigv4_insecure` override from `base/trim-override.yaml`. S3 `PUT`
  works again with the CVE-2026-54330 hardening re-enabled.

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

## Storage Class Image Features

### CI StorageClass (`rook-ceph-block-virtualization-ci`)

**Change date:** 2026-10-28

**Feature:** `imageFeatures` in `kubernetes/ceph/components/block-ci/storage-class.yaml`

**Before:**

```yaml
imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff
```

**After:**

```yaml
imageFeatures: layering,deep-flatten,exclusive-lock
```

**Removed features:**

| Feature      | Purpose                                     | Why safe to remove                 |
| ------------ | ------------------------------------------- | ---------------------------------- |
| `object-map` | Bitmap tracking for thin-provisioned clones | VMs use isolated disks, not shared |
| `fast-diff`  | Efficient zero-detection for copy-on-write  | No shared disk scenarios           |

**Kept features:**

| Feature          | Purpose                                  |
| ---------------- | ---------------------------------------- |
| `layering`       | RBD image layering support               |
| `deep-flatten`   | Efficient deep clone flattening          |
| `exclusive-lock` | Prevents concurrent writes to same image |

**Impact:**

| Metric                                    | Before                 | After                |
| ----------------------------------------- | ---------------------- | -------------------- |
| First write throughput (thin-provisioned) | ~17 MB/s               | ~150-200 MB/s        |
| Per-write overhead                        | +object-map +fast-diff | None                 |
| Clone performance                         | ~1s (with bitmap)      | ~1s (same)           |
| Data safety                               | 3 replicas (size: 2)   | 3 replicas (size: 2) |

**Risk:** Only breaks if multiple VMs write to the same RBD image concurrently. For isolated VM disks (the only current usage), safe to remove.

**Production StorageClass** (`rook-ceph-block`, `rook-ceph-block-virtualization`) — **unmodified** due to live migration and potential shared disk scenarios in production workloads.

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
