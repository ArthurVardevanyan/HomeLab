# Intel GPU DRA Experimental Overlay (DRAFT)

> **[DRAFT / EXPERIMENTAL]** This overlay is provided for experimentation and
> evaluation only. **It is NOT wired to any ArgoCD Application** and therefore
> will not be deployed to any cluster. It is safe to merge.

## Overview

This kustomize overlay installs the [Intel GPU Resource Driver for
Kubernetes](https://github.com/intel/intel-resource-drivers-for-kubernetes)
(v0.12.0) which implements **Direct Resource Allocation (DRA)** for Intel GPUs.
Unlike the existing `GpuDevicePlugin` approach, DRA uses the Kubernetes-native
`DeviceClass` + `ResourceClaimTemplate`/`ResourceClaim` model.

### Image Pin

| Image                                     | Version   | SHA-256 Digest                                                            |
| ----------------------------------------- | --------- | ------------------------------------------------------------------------- |
| `ghcr.io/intel/intel-gpu-resource-driver` | `v0.12.0` | `sha256:5be06e1cf810c6091cec17ed78a775be64323f2084038c8840f283f643ce4207` |

Renovate will keep this pin up to date via the `# renovate:
datasource=docker` comment annotation above the image reference.

## How DRA Differs from the GpuDevicePlugin Approach

| Aspect           | GpuDevicePlugin (current)                     | DRA (this overlay)                             |
| ---------------- | --------------------------------------------- | ---------------------------------------------- |
| Allocation model | Extended resources (`gpu.intel.com/xe: "4"`)  | `ResourceClaim` with `DeviceClass` selector    |
| Sharing          | `sharedDevNum: 3` → 3 virtual devices per GPU | Whole physical GPU only (no sharing)           |
| Scheduling       | Standard `resources.requests.limits`          | `resourceClaims` pod spec field                |
| Device selection | `ONEAPI_DEVICE_SELECTOR=level_zero:0/1`       | Device binding via CDI / device class          |
| Dynamic          | No — static count at node level               | Yes — kubelet plugin reports available devices |

### Key Implications

1. **No sharing:** DRA allocates whole physical GPUs. The `count` field in a
   `ResourceClaimTemplate` specifies the exact number of GPUs to allocate —
   there is no `sharedDevNum` equivalent. A request for `count: 1` consumes one
   full physical GPU.

2. **DeviceClass selectors:** The `gpu.intel.com` DeviceClass uses a CEL
   expression to match devices where `device.driver == "gpu.intel.com"`. This
   is device-class-aware and does not rely on extended resource counts.

3. **NFD labeling:** This overlay includes NodeFeatureRule resources that
   produce the `intel.feature.node.kubernetes.io/gpu: "true"` label. If your
   cluster already uses a different NFD labeling scheme for the Xe driver, you
   may need to adjust or remove these rules.

4. **Requires CRDs at first sync:** The `ResourceClass` and
   `ValidatingAdmissionPolicy` resources require `--allow-missing-intersections`
   or ArgoCD sync-options with `SkipDryRunOnMissingResource=true`. The overlay
   adds `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` to
   resources that reference CRDs not present in the base overlay.

## What This Overlay Installs

- **Namespace:** `intel-gpu-resource-driver`
- **DeviceClass:** `gpu.intel.com` (CEL-based selector matching `driver == "gpu.intel.com"`)
- **DeviceClass:** `gpu-vfio.intel.com` (for VFIO/VM workloads)
- **DaemonSet:** `intel-gpu-resource-driver-kubelet-plugin` (the DRA kubelet plugin)
- **RBAC:** ServiceAccount, ClusterRole, ClusterRoleBinding for the plugin
- **ValidatingAdmissionPolicy:** Restricts ResourceSlice writes to the plugin SA
- **NFD NodeFeatureRules:** Labels GPU nodes and classifies device families

## Future Work

- When DRA driver matures or if Intel adds sharing support, revisit
  allocation policies
- Evaluate whether `gpu.intel.com` device-class selectors need refinement for
  the Intel Arc Pro B70 (Xe2) platform
- Add per-device resource limits/requests if the plugin supports per-device
  attributes (memory, compute units)

## References

- [Intel Resource Drivers for Kubernetes](https://github.com/intel/intel-resource-drivers-for-kubernetes)
  (tag: `gpu-v0.12.0`)
- [Kubernetes DRA KEP](https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/5004-dra-extended-resource)
- [OpenShift DRA documentation](https://docs.openshift.com/container-platform/latest/scalability_and_performance/using-device-advanced-resource-allocation-dra.html)
