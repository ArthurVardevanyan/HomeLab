# OKD Nodes

Per-node `BareMetalHost` + `Machine` + `MachineSet` definitions for the OKD cluster, managed via Kustomize under `okd/okd-nodes/`.

## Architecture

Each node follows a three-resource flow:

```txt
BareMetalHost (metal3.io) → Machine (machine.openshift.io) → MachineSet (machine.openshift.io)
```

- **BareMetalHost (BMH)** — declares BMC address, boot MAC, credentials, and `externallyProvisioned: true`
- **Machine** — minimal resource with `clusterName: okd-4ww5p`; the Machine API Operator links it to the BMH
- **MachineSet** — carries the role label, instance-type, zone, taints, `hostSelector`, and user data

Server nodes use `./machine/` (one Machine per node). Worker nodes do not have a corresponding Machine resource — only BMH + MachineSet. The MachineSet's `hostSelector` (matching `kubernetes.io/hostname`) is what matters.

## Manual BMH Status Patching

Bare-metal nodes have no cloud provider, so the BMH lacks `status.hardware.nics`. Without this, the Machine API Operator cannot link the Machine to the node by IP and the MachineSet never adopts it.

**This must be done manually after each node is installed**, by patching the BMH status with the node's primary NIC IP/MAC:

```bash
# Server nodes (masters) — already patched during initial install
kubectl patch bmh server-1 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.101","mac":"98:b7:85:22:14:04","name":"bond0"}]}}}'
kubectl patch bmh server-2 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.102","mac":"98:b7:85:21:ed:db","name":"bond0"}]}}}'
kubectl patch bmh server-3 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.103","mac":"98:b7:85:21:ed:e7","name":"bond0"}]}}}'

# Worker nodes — patch after enrollment
kubectl patch bmh worker-1 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.104","mac":"58:47:CA:7A:74:FD","name":"primary"}]}}}'
kubectl patch bmh worker-2 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.105","mac":"58:47:CA:7C:4C:BF","name":"primary"}]}}}'
kubectl patch bmh worker-3 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.106","mac":"58:47:CA:7A:76:2B","name":"primary"}]}}}'

# GPU node
kubectl patch bmh gpu-1 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.107","mac":"2c:f0:5d:83:73:a2","name":"bond0"}]}}}'
```

The patch command for each node is also documented in the commented-out `status:` block in `okd/okd-nodes/base/bmh/<node>.yaml`.

### Verifying the patch took effect

```bash
oc get bmh <node> -n openshift-machine-api -o jsonpath='{.status.hardware.nics}{"\n"}'
oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=okd-4ww5p-<role>-<n> -o wide
```

The Machine should have `PHASE: Running` and a `NODE` name.

## Nodes

| Hostname | Role   | BMH Systems/ | MachineSet         | Instance Type | Zone | Taint          |
| -------- | ------ | ------------ | ------------------ | ------------- | ---- | -------------- |
| server-1 | master | 1            | (no MachineSet)    | R7-5700G      | 1    | —              |
| server-2 | master | 2            | (no MachineSet)    | R7-5700G      | 2    | —              |
| server-3 | master | 3            | (no MachineSet)    | R7-5700G      | 3    | —              |
| worker-1 | worker | 4            | okd-4ww5p-worker-1 | MS-A1-A5870   | 1    | —              |
| worker-2 | worker | 5            | okd-4ww5p-worker-2 | MS-A1-A5870   | 2    | —              |
| worker-3 | worker | 6            | okd-4ww5p-worker-3 | MS-A1-A5870   | 3    | —              |
| gpu-1    | worker | 7            | okd-4ww5p-gpu-1    | R5-3600       | —    | gpu:NoSchedule |

Workers use per-node MachineSets with `replicas: 0` — they exist as declarative records only. ArgoCD ignores the replicas field via `ignoreDifferences`, so scaling a MachineSet to 1 later (e.g., for node replacement) is safe.

## Destructive Scaling Warning

Scaling a per-node MachineSet to 1 **power-cycles the physical host**. This is destructive for hosts that are live cluster members:

- `replicas: 1` → Machine controller claims the BMH → sets `spec.online: true` → host powers on
- `replicas: 0` (or deleting the Machine) → BMH sets `spec.online: false` → host powers off

For live nodes (like gpu-1), this means the node will be ejected from the cluster during scale-down. Workers (1-3) are safe because they have no MachineSet (replicas stays 0) and no node in the cluster.

If you need to test scale-up/scale-down on a live node, always check `spec.online` and BMH state first:

```bash
oc get bmh <node> -n openshift-machine-api -o jsonpath='online={.spec.online}{"\n"}poweredOn={.status.poweredOn}{"\n"}consumerRef={.spec.consumerRef}{"\n"}'
```

## Node Maintenance & Troubleshooting

### XFS Filesystem Corruption Repair (`nvme0n1p4`)

**The Issue:** Force-power-cycling during initial GPU lockup troubleshooting caused metadata corruption on `/dev/nvme0n1p4` (the stateful `/var` partition on CentOS Stream CoreOS). This resulted in I/O hangs, causing Kubelet and CRI-O to crash and flap the node status (`Ready` $\leftrightarrow$ `NotReady`).

**The Fix:**

1. Interrupt dracut initramfs bootloader with `rd.break=pre-mount` to bypass OSTree's read-write overlayfs layer.
2. Execute offline repair on the unmounted block device:

```bash
xfs_repair -L /dev/nvme0n1p4
```

### NIC Speed Negotiation

Power save mode settings cause the NIC to negotiate at FE speeds. The workaround was forcing the switch-side port to 2.5G (auto-negotiation was unreliable; this is what worked).

## Adding a New Node

1. Create `okd/okd-nodes/base/bmh/<hostname>.yaml` — BMH + ExternalSecret, following `worker-3.yaml`
2. Create `okd/okd-nodes/base/machine-set/<hostname>.yaml` — MachineSet following `worker-3.yaml`
3. Update `kubernetes/bmc-shim/base/configmap.yaml` — append `,<N>=switch.<entity>` to `ha_systems`
4. Add both files to `okd/okd-nodes/base/kustomization.yaml`
5. Run `bash main.bash kustomize_fix --dir okd/okd-nodes`

## Bmc-shim Integration

Each node is mapped to an HA switch entity in `kubernetes/bmc-shim/base/configmap.yaml` under `ha_systems`. The BMC address in each BMH references this mapping (e.g., `Systems/1` → `switch.power_strip_zone_1_kvm_1`).

## Validation

```bash
# Kustomize fix + document markers
bash main.bash kustomize_fix --dir okd/okd-nodes

# CI validation (skip AVP — no Vault needed for these manifests)
k8s-gitops-ci test-all --app okd/okd-nodes --cluster okd --assume-openshift --disable-checks avp
```
