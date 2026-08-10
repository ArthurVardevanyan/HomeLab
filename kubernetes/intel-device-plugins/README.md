# Intel Device Plugins (GPU)

Installs the Intel Device Plugins Operator (via OLM) and a `GpuDevicePlugin`
custom resource that advertises the Intel Arc Pro B70 (Battlemage / Xe2, `xe`
KMD) to the kubelet as the `gpu.intel.com/xe` extended resource.

## Table of Contents

- [Scheduling](#scheduling)
- [GPU Monitoring (nvidia-smi equivalents)](#gpu-monitoring-nvidia-smi-equivalents)
  - [From the host / a node debug shell](#from-the-host--a-node-debug-shell)
  - [From inside the LLM pod](#from-inside-the-llm-pod)
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

### From inside the LLM pod

```bash
export KUBECONFIG=$HOME/.kube/okd

# Scale the workload up first (defaults to replicas: 0)
oc -n llm scale deployment/llm-server --replicas=1

POD=$(oc -n llm get pod -l app=llm-server -o name | head -1)

# Enumerate SYCL / Level-Zero devices the runtime sees (like nvidia-smi -L)
oc -n llm exec "$POD" -- sycl-ls

# Full SMI dashboard: utilization, memory, power, temp, health
oc -n llm exec "$POD" -- xpu-smi discovery      # list devices + static info
oc -n llm exec "$POD" -- xpu-smi stats -d 0     # live stats for device 0
oc -n llm exec "$POD" -- xpu-smi dump -d 0 -m 0,1,2,3,18  # stream metrics

# What models is the LLM serving (workload-level check)
oc -n llm exec "$POD" -- wget -qO- http://localhost:11434/v1/models
```

`xpu-smi stats -d 0` metric groups map roughly to `nvidia-smi` columns:
GPU Utilization, GPU Memory Used, GPU Power, GPU Frequency, GPU Temperature.

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
  | tr ',' '\n' | grep -i 'custom-intel.xe.gpu\|pci-0300\|8086'
```

If the `custom-intel.xe.gpu` label is absent, the `intel-xe-gpu`
`NodeFeatureRule` did not match — check that the `xe` module is loaded and the
Intel display-class PCI device is present (`lspci -nnk` on the node), then
inspect the nfd-worker logs in the `openshift-nfd` namespace.
