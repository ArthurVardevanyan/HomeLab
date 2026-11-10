# VolumeAttributesClass for RBD – Spike Analysis

## Table of Contents

- [VolumeAttributesClass for RBD – Spike Analysis](#volumeattributesclass-for-rbd--spike-analysis)
  - [Findings](#findings)
  - [Support Matrix](#support-matrix)
  - [csi-resizer Capabilities](#csi-resizer-capabilities)
  - [Limitations](#limitations)
  - [Conclusion](#conclusion)

## Findings

ceph-csi **v3.17.1** includes `ControllerModifyVolume` support for RBD:

- Feature added in **v3.17.0** (Alpha stage)
- Uses the VolumeAttributesClass feature to implement RBD volume QoS via `ControllerModifyVolume`
- Allows dynamic QoS parameter changes without recreating volumes

This was confirmed from:

- [ceph-csi README](https://github.com/ceph/ceph-csi/blob/v3.17.1/README.md) feature table
- [v3.17.0 release notes](https://github.com/ceph/ceph-csi/releases/tag/v3.17.0)
- [v3.17.1 release notes](https://github.com/ceph/ceph-csi/releases/tag/v3.17.1)
- Source: `internal/rbd/controllerserver.go` → `ControllerModifyVolume()`

## Support Matrix

| CSI Driver | Feature                          | Version    | Mounter       | Status |
| ---------- | -------------------------------- | ---------- | ------------- | ------ |
| RBD        | ControllerModifyVolume (VAC QoS) | >= v3.17.0 | **NBD only**  | Alpha  |
| RBD        | Expand volume (size only)        | >= v3.7.0  | krbd + nbd    | Alpha  |
| CephFS     | ControllerModifyVolume (VAC)     | >= v3.17.0 | kernel + fuse | Alpha  |
| NFS        | ControllerModifyVolume           | >= v3.16.0 | -             | Alpha  |
| NVMe-oF    | ControllerModifyVolume           | >= v3.16.0 | -             | Alpha  |

Reference: [ceph-csi README — features table](https://github.com/ceph/ceph-csi/blob/v3.17.1/README.md)

## csi-resizer Capabilities

The csi-resizer sidecar (`v2.1.0`) deployed by this cluster includes modify-volume support:

- `--modify-timeout` flag for `ControllerModifyVolume` calls
- `--extra-modify-metadata` flag to include PV/PVC metadata in modify requests
- Registered as a component in the Driver CR (`spec.controllerPlugin.resources.resizer`)

## Limitations

1. **NBD-only for RBD QoS**: The VolumeAttributesClass QoS feature is **only supported for the NBD mounter**, not for krbd. The current `rook-ceph-block` StorageClass uses krbd (the default mounter).

2. **Alpha status**: The feature is marked as Alpha in ceph-csi — backward-incompatible changes are possible.

3. **Kubernetes 1.34+ required**: VolumeAttributesClass (`storage.k8s.io/v1alpha1` → `storage.k8s.io/v1`) requires Kubernetes 1.34+ for the stable `VolumeAttributesClass` resource. The target cluster (OKD 5.0 / K8s 1.36.5) meets this requirement.

4. **No CRD needed**: `VolumeAttributesClass` is a built-in Kubernetes resource (no custom CRD installation required).

5. **MDS pinning for CephFS**: While the ControllerModifyVolume is implemented for CephFS (MDS pinning via `PinSubVolumeInGroup`), that's a separate use case.

## Conclusion

**Won't-do for `rook-ceph-block` StorageClass** — the VAC feature for RBD is only supported with the NBD mounter, but the default block StorageClass uses krbd.

A VAC can only be practically useful for:

- Workloads already using the **NBD mounter** (e.g., the existing `rook-ceph-block-virtualization` StorageClass uses `mounter: rbd` which routes through NBD, but explicit NBD QoS tuning may still apply)
- Future NBD-default block classes if krbd is dropped

**Recommendation**: Track this feature for potential future use when workloads shift to NBD mounter exclusively. Do not implement for the current krbd-based `rook-ceph-block` StorageClass.
