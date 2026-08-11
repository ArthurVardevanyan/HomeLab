# Intel Device Plugins (GPU)

Installs the Intel Device Plugins Operator (via OLM) and a `GpuDevicePlugin`
custom resource that advertises the Intel Arc Pro B70 (Battlemage / Xe2, `xe`
KMD) to the kubelet as the `gpu.intel.com/xe` extended resource.

## Table of Contents

- [Scheduling](#scheduling)
- [GPU Monitoring (nvidia-smi equivalents)](#gpu-monitoring-nvidia-smi-equivalents)
  - [From the host / a node debug shell](#from-the-host--a-node-debug-shell)
  - [From inside a gpu-toolbox debug pod](#from-inside-a-gpu-toolbox-debug-pod)
  - [From Kubernetes (scheduling / capacity view)](#from-kubernetes-scheduling--capacity-view)
- [Verify the plugin and node labels](#verify-the-plugin-and-node-labels)

## Scheduling

The `GpuDevicePlugin` DaemonSet and the GPU workloads are pinned to the GPU
node (`gpu-1`) via the NFD label
`feature.node.kubernetes.io/custom-intel.xe.gpu=true` (produced by the
`intel-xe-gpu` `NodeFeatureRule` in the
`node-feature-discovery-operator` app) and tolerate the
`node-role.kubernetes.io/gpu:NoSchedule` taint.

## GPU Monitoring (nvidia-smi equivalents)

Intel GPUs do not use `nvidia-smi`. The closest equivalents are `xpu-smi`
(System Management Interface, the direct analog), `intel_gpu_top` (live
utilization, like `nvtop`), and raw sysfs reads.

### From the host / a node debug shell

Open a root shell on the GPU node:

```bash
export KUBECONFIG=$HOME/.kube/okd
oc debug node/gpu-1
# then, inside the debug pod:
chroot /host
```

Confirm the card and driver binding (equivalent to `nvidia-smi -L`):

```bash
# Which driver claims the Intel GPU (want: xe)
lspci -nnk | grep -iA3 'VGA\|Display\|8086'

# xe module loaded?
lsmod | grep -E '^xe|^i915'

# DRI render/card device nodes present?
ls -l /dev/dri/ /dev/dri/by-path/
```

Live utilization (closest to `watch nvidia-smi` / `nvtop`), if
`intel-gpu-tools` is available on the host:

```bash
# Whole-GPU engine utilization, memory, power, frequency
intel_gpu_top

# One-shot, machine-readable
intel_gpu_top -J -s 1000    # JSON samples every 1000 ms
```

Sysfs frequency / power (no tools required):

```bash
# Current / max GPU frequency (MHz)
cat /sys/class/drm/card*/gt/gt0/rps_cur_freq_mhz 2>/dev/null
cat /sys/class/drm/card*/gt/gt0/rps_max_freq_mhz 2>/dev/null

# Energy counter (microjoules) — sample twice and diff for power
cat /sys/class/drm/card*/device/hwmon/hwmon*/energy1_input 2>/dev/null
```

### From inside a gpu-toolbox debug pod

The `gpu-toolbox` image ships VA-API/FFmpeg and Intel diagnostics (`clinfo`,
`xpu-smi`, `vainfo`, `intel-gpu-tools`). Run it as a debug pod with access to
`/dev/dri/render` — the `render` supplementalGroup (`44`) is required for
device access on OpenShift.

```bash
export KUBECONFIG=$HOME/.kube/okd

# Option A: ephemeral container on the GPU node (preferred)
oc debug node/gpu-1 -- chroot /host /bin/bash
# Inside: clinfo -l, xpu-smi, vainfo, ffmpeg (no extra setup)

# Option B: standalone pod
oc run gpu-toolbox-debug --image=ghcr.io/arthurvardevanyan/gpu-toolbox:latest \
  --restart=Never -it --rm \
  --overrides='{"spec":{"supplementalGroups":[44],"volumes":[{"name":"dri","hostPath":{"path":"/dev/dri"}}],"containers":[{"name":"gpu-toolbox-debug","imagePullPolicy":"IfNotPresent","securityContext":{"runAsNonRoot":false},"volumeMounts":[{"name":"dri","mountPath":"/dev/dri"}]}]}}'

POD=$(oc get pod -l run=gpu-toolbox-debug -o name --field-selector=status.phase=Running)
```

Device enumeration and encoding verification:

```bash
# OpenCL device enumeration (like nvidia-smi -L)
oc exec "$POD" -- clinfo -l

# SMI: list devices + static info
oc exec "$POD" -- xpu-smi discovery
# SMI: live stats for device 0
oc exec "$POD" -- xpu-smi stats -d 0

# VA-API: check for VAEntrypointEncSlice support
oc exec "$POD" -- vainfo --display drm --device /dev/dri/renderD128

# Hardware encode smoke test: 5s of 1080p30 → h264_vaapi → null
oc exec "$POD" -- ffmpeg -y -hide_banner \
  -init_hw_device vaapi=hw:/dev/dri/renderD128 \
  -f lavfi -i testsrc=size=1920x1080:rate=30:duration=5 \
  -vf format=nv12,hwupload \
  -c:v h264_vaapi -f null -
```

`xpu-smi stats -d 0` metric groups map roughly to `nvidia-smi` columns:
GPU Utilization, GPU Memory Used, GPU Power, GPU Frequency, GPU Temperature.

Note: `intel_gpu_top` may fail against the `xe` KMD — Ubuntu 24.04 ships
`igt-gpu-tools` 1.28, but `xe` support requires 1.29+. Use the sysfs reads
in the host section above as a fallback.

### From Kubernetes (scheduling / capacity view)

This is the "how many GPUs does the scheduler see" view — not live
utilization, but confirms the device plugin is advertising the resource.

```bash
export KUBECONFIG=$HOME/.kube/okd

# Allocatable Intel GPU resource on the node (xe fan-out = sharedDevNum)
oc get node gpu-1 -o jsonpath='{.status.allocatable.gpu\.intel\.com/xe}{"\n"}'

# Everything using the resource, and how much
oc describe node gpu-1 | grep -A15 'Allocated resources'

# Pods currently requesting the Intel GPU
oc get pods -A -o json \
  | jq -r '.items[] | select(
      [.spec.containers[].resources.limits // {} | keys[]]
      | index("gpu.intel.com/xe")
    ) | "\(.metadata.namespace)/\(.metadata.name)"'
```

## Verify the plugin and node labels

```bash
export KUBECONFIG=$HOME/.kube/okd

# GpuDevicePlugin CR status (Desired / Ready node counts)
oc get gpudeviceplugins.deviceplugin.intel.com intel-gpu-plugin

# Plugin DaemonSet pods — should run ONLY on gpu-1
oc -n intel-device-plugins-operator get pods -o wide

# Confirm the NFD label that gates scheduling actually landed on gpu-1
oc get node gpu-1 -o jsonpath='{.metadata.labels}' \
  | tr ',' '\n' | grep -i 'custom-intel.xe.gpu'
```

If the `custom-intel.xe.gpu` label is absent, the `intel-xe-gpu`
`NodeFeatureRule` did not match — check that the `xe` module is loaded and the
Intel display-class PCI device is present (`lspci -nnk` on the node), then
inspect the nfd-worker logs in the `openshift-nfd` namespace.

## Re-rendering the chart

After changing `values.yaml`, regenerate the manifest files:

```bash
helm template xpumd oci://ghcr.io/intel/xpumanager/charts/xpumd \
  --version 2.0.1 --namespace intel-device-plugins-operator \
  -f kubernetes/intel-device-plugins/values.yaml \
  > /tmp/xpumd-rendered.yaml
```

Then apply post-render edits (namespace, sync-waves, PodSpec defaults,
renovate annotations) to the individual YAML files under
`base/xpumd/` and remove any resources not rendered for the active
`gpuAccess` mode (e.g. `ResourceClaimTemplate` when `gpuAccess: plugin`).

The `intelxpuinfo` exporter, `intel_crashlog` receiver, and both hostPath
volumes (`/run/xpumd`, `/var/log/crashlog`) are deleted post-render because
the chart hard-codes them in the daemonset template. After any ConfigMap
change, restart the DaemonSet so the rolling update picks up the new values:

```bash
oc -n intel-device-plugins-operator rollout restart ds/xpumd
```
