# OKD Nodes

Per-node `BareMetalHost` + `Machine` + `MachineSet` definitions for the OKD cluster, managed via Kustomize under `okd/okd-nodes/`.

## Table of Contents

- [OKD Nodes](#okd-nodes)
  - [Table of Contents](#table-of-contents)
  - [Architecture](#architecture)
  - [Nodes](#nodes)
  - [Native Provisioning](#native-provisioning)
    - [Provisioning Flow](#provisioning-flow)
    - [Per-Host Settings](#per-host-settings)
    - [Usage](#usage)
    - [Manual BMH Status Patching](#manual-bmh-status-patching)
    - [Host Prerequisites](#host-prerequisites)
  - [Supporting Pieces](#supporting-pieces)
  - [Rollout and End-to-End Test](#rollout-and-end-to-end-test)
  - [Known Issues](#known-issues)
  - [Destructive Scaling Warning](#destructive-scaling-warning)
  - [Node Maintenance \& Troubleshooting](#node-maintenance--troubleshooting)
    - [XFS Filesystem Corruption Repair (`nvme0n1p4`)](#xfs-filesystem-corruption-repair-nvme0n1p4)
    - [NIC Speed Negotiation](#nic-speed-negotiation)
  - [Adding a New Node](#adding-a-new-node)
  - [Bmc-shim Integration](#bmc-shim-integration)
  - [Validation](#validation)

## Architecture

Each node follows a three-resource flow:

```txt
BareMetalHost (metal3.io) → Machine (machine.openshift.io) → MachineSet (machine.openshift.io)
```

- **BareMetalHost (BMH)** — declares BMC address, boot MAC, credentials, and `externallyProvisioned` (`true` for the masters and gpu-1; omitted, meaning `false`, for the natively provisioned workers)
- **Machine** — minimal resource with `clusterName: okd-4ww5p`; the Machine API Operator links it to the BMH
- **MachineSet** — carries the role label, instance-type, zone, taints, `hostSelector`, and user data

Server nodes use `./machine/` (one Machine per node). Worker nodes have no Machine in git; the MachineSet creates it when scaled to 1. The MachineSet's `hostSelector` (matching `kubernetes.io/hostname`) picks the BMH.

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

Workers use per-node MachineSets. The replica count is not in git and ArgoCD ignores it via `ignoreDifferences` (MachineSet `/spec/replicas`, BMH `/spec/online`), so scaling up or down is not reverted.

## Native Provisioning

worker-1, worker-2 and worker-3 are natively provisioned (`externallyProvisioned` is `false`), so metal3/Ironic installs the OS itself over PXE. The field is **commented out** in `bmh/worker-*.yaml`: `false` is the API default and is dropped when the object is written, so declaring it leaves ArgoCD permanently OutOfSync. gpu-1 and the masters stay `externallyProvisioned: true` (gpu-1 carries commented-out native settings in `bmh/gpu-1.yaml` for later).

- **Scale up** (`replicas: 1`) → Machine created and claims the BMH → Ironic cleans the disk, PXE boots the agent and runs `install_coreos` with the `worker-user-data-managed` Ignition → node joins the cluster.
- **Scale down** (`replicas: 0`) → Machine deleted → BMH deprovisions (cleaning with `automatedCleaningMode: metadata`) and powers off.

### Provisioning Flow

```txt
MachineSet ──> Machine ──> BareMetalHost ──> Ironic (metal3 pod, on a master)
                                  │                     │
                    bmc-shim (Redfish power)     PXE: snponly-homelab.efi
                    Home Assistant smart plug    -> /pxelinux.cfg/<mac> -> agent
```

1. The BMH `bmc.address` is `redfish+http://bmc-shim.bmc-shim.svc.cluster.local:8080/redfish/v1/Systems/<n>`. The shim turns Redfish power requests into a Home Assistant switch call (see [Bmc-shim Integration](#bmc-shim-integration)).
2. The host powers on and PXE boots the custom iPXE binary. See [base/metal3-pxe/README.md](base/metal3-pxe/README.md) for how that binary and its CronJob work.
3. The agent installs CentOS Stream CoreOS to the NVMe disk with the network config from the `<host>-network-data` Secret (`preprovisioningNetworkDataName`).
4. After the install Ironic leaves a per-MAC config that boots the local disk.

### Per-Host Settings

Every natively provisioned BMH sets:

| Field                                                        | Why                                                                                                     |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| `annotations: baremetalhost.metal3.io/boot-interface: ipxe`  | Use iPXE boot, not virtual media                                                                        |
| `bmc.address: redfish+http://…` (not `redfish-virtualmedia`) | The shim has no virtual media; it only controls power                                                   |
| `architecture: x86_64`                                       | Required when inspection is off so the right image is picked                                            |
| `inspectionMode: disabled`                                   | Hardware is fixed and the shim cannot support IPA inspection                                            |
| `rootDeviceHints.deviceName: /dev/nvme0n1`                   | Without inspection BMO defaults to `/dev/sda`, which fails with `DeviceNotFound`. NVMe is the only disk |
| `preprovisioningNetworkDataName: <host>-network-data`        | Static `bond0` config for the agent and the installed OS                                                |

`base/network-data/*.yaml` hold the per-host nmstate (static IP, active-backup bond on `enp3s0`/`enp4s0`, MTU 9000, default route via `10.101.10.1`).

### Usage

```bash
# Scale all three workers down (deprovision + power off):
bash main.bash okd_bm_worker_shutdown

# Scale all three workers up (provision + join cluster):
bash main.bash okd_bm_worker_startup
```

Both functions default `KUBECONFIG` to `~/.kube/okd`. To do a single host, patch its MachineSet directly:

```bash
kubectl -n openshift-machine-api patch machineset okd-4ww5p-worker-1 --type merge -p '{"spec":{"replicas":1}}'
```

Watch progress:

```bash
kubectl -n openshift-machine-api get bmh,machine -w
```

### Manual BMH Status Patching

Because inspection is disabled, `BMH.status.hardware` stays empty. The Machine then has no addresses, the `nodelink` controller cannot match the Node by IP, and the Machine never gets a `nodeRef`. The node itself is `Ready` and works; only the Machine/Node link is missing.

**Patch the status after each (re)provision**, once the node is up. Use the interface name `bond0`:

```bash
kubectl patch bmh worker-1 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.104","mac":"58:47:CA:7A:74:FD","name":"bond0"}]}}}'
kubectl patch bmh worker-2 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.105","mac":"58:47:CA:7C:4C:BF","name":"bond0"}]}}}'
kubectl patch bmh worker-3 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.106","mac":"58:47:CA:7A:76:2B","name":"bond0"}]}}}'
kubectl patch bmh gpu-1    -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.107","mac":"2c:f0:5d:83:73:a2","name":"bond0"}]}}}'
# Masters (patched once at install):
kubectl patch bmh server-1 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.101","mac":"98:b7:85:22:14:04","name":"bond0"}]}}}'
kubectl patch bmh server-2 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.102","mac":"98:b7:85:21:ed:db","name":"bond0"}]}}}'
kubectl patch bmh server-3 -n openshift-machine-api --type merge --subresource status --patch '{"status":{"hardware":{"nics":[{"ip":"10.101.10.103","mac":"98:b7:85:21:ed:e7","name":"bond0"}]}}}'
```

This is live status, so it is **not** in git. BMO clears the status when metal3 restarts and Ironic re-registers the host, so repeat it if a Machine loses its address.

Verify:

```bash
oc get bmh <node> -n openshift-machine-api -o jsonpath='{.status.hardware.nics}{"\n"}'
oc get machine -n openshift-machine-api -o wide
```

The Machine should show `PHASE: Running` and a `NODE` name, and the Node should have `spec.providerID: baremetalhost:///openshift-machine-api/<bmh>/<uid>`.

### Host Prerequisites

- **PXE first.** Keep the network boot entry first in the BIOS boot order. Cleaning and teardown need the host to PXE into the agent.
- **Restore on AC power loss: Power On.** The shim switches a smart plug. A host that stays off when power returns after a clean shutdown cannot be started again.
- **"Boot Option Restoration" screen.** After the first install the shim fallback loader resets the machine in a loop until you select **Always continue boot** once on the console. This is a one-time, per-host step stored in NVRAM. Details and caveats are in [base/metal3-pxe/README.md](base/metal3-pxe/README.md#known-issue-boot-option-restoration-loop).
- **Disk.** Every host has a single NVMe disk. A host with a second disk needs a different `rootDeviceHints`.

## Supporting Pieces

Everything in this change set, and where it lives:

| Piece                                     | Location                                            | What it does                                                                                                                                          |
| ----------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| BMH, network data, `Provisioning` CR      | `okd/okd-nodes/base/`                               | Native provisioning settings. `provisioning.yaml` pins `provisioningIP: 10.101.11.250` on `prov-shim` with `provisioningNetwork: Unmanaged`           |
| Custom iPXE EFI + sync CronJob            | `okd/okd-nodes/base/metal3-pxe/`                    | Gets around the router's fixed boot filename and the RTL8125 NICs. See its README                                                                     |
| `prov-shim` interface and VLAN 11 routing | `kubernetes/nmstate/overlays/okd/network/nncp.yaml` | OVS interface on `br4.11` that carries the metal3 provisioning IP, plus a policy route for `10.101.11.200/32` (table 111)                             |
| Loose reverse path filter on masters      | `okd/okd-configuration/components/rp-filter-loose/` | `net.ipv4.conf.all.rp_filter=2` via Tuned. metal3 sits on VLAN 11 and the hosts reply from `10.101.10.0/24`; strict mode drops that traffic           |
| bmc-shim `v0.3.0`                         | `kubernetes/bmc-shim/base/deployment.yaml`          | Adds `PATCH` of the nested `Boot` object and the `Managers` stubs Ironic needs ([bmc-shim#36](https://github.com/ArthurVardevanyan/bmc-shim/pull/36)) |
| `okd_bm_worker_shutdown` / `_startup`     | `main.bash`                                         | Scale all worker MachineSets down or up                                                                                                               |

## Rollout and End-to-End Test

ArgoCD syncs the `okd-nodes`, `nmstate`, `okd-configuration` and `bmc-shim` applications. Order matters a little:

1. **Sync `bmc-shim` first** and wait for both replicas to be ready on `v0.3.0`. Check:

   ```bash
   kubectl -n bmc-shim get deploy bmc-shim -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

2. **Sync `okd-configuration`** (Tuned profile) and confirm the masters:

   ```bash
   kubectl -n openshift-cluster-node-tuning-operator get profile
   for n in server-1 server-2 server-3; do oc debug node/$n -q -- chroot /host sysctl net.ipv4.conf.all.rp_filter; done   # expect 2
   ```

3. **Sync `nmstate`** and check the `NodeNetworkConfigurationPolicy` is `Available`, and that `prov-shim` exists on server-1 (where metal3 runs).
4. **Sync `okd-nodes`**. This creates the BMHs, network-data Secrets, the `Provisioning` CR and the `metal3-pxe-sync` CronJob. Hosts that are `available` with MachineSets at 0 are only registered, not wiped.
5. **Run the CronJob once** instead of waiting up to 10 minutes, and verify the EFI:

   ```bash
   kubectl -n openshift-machine-api create job --from=cronjob/metal3-pxe-sync pxe-sync-manual
   kubectl -n openshift-machine-api logs job/pxe-sync-manual
   ```

6. **Test on one worker first.** Scale `okd-4ww5p-worker-1` to 1 and watch:

   | Expected step                                                   | How to see it                                                                        |
   | --------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
   | BMH `provisioning` then `provisioned` (10–15 min from scale-up) | `kubectl -n openshift-machine-api get bmh -w`                                        |
   | Host fetches the EFI and deploy kernel                          | `metal3-dnsmasq` and `metal3-httpd` logs                                             |
   | Host reboots into the installed OS                              | Pings on `10.101.10.104`. If it loops, see the "Boot Option Restoration" known issue |
   | Node `Ready`, no pending CSRs                                   | `kubectl get nodes; kubectl get csr`                                                 |
   | Machine linked                                                  | Apply the [status patch](#manual-bmh-status-patching); Machine gets a `nodeRef`      |

7. **Test teardown** by scaling back to 0. The host must clean and power off, which also proves PXE is still first in the boot order.
8. Then repeat for worker-2 and worker-3, or use `okd_bm_worker_startup`.

If a host ends up in `error`, check `kubectl -n openshift-machine-api get bmh <host> -o jsonpath='{.status.errorMessage}'` and the `metal3-ironic` container logs.

## Known Issues

- **Boot Option Restoration loop** after the first install; one console click per host. See [base/metal3-pxe/README.md](base/metal3-pxe/README.md#known-issue-boot-option-restoration-loop).
- **Status patch is not in git.** `BMH.status.hardware.nics` must be re-applied after a reprovision or a metal3 restart.
- **bmc-shim reports plug state, not machine state.** `PowerState` can say `On` while the host is shut down. Boot override state is also per replica and is not applied to the machine.
- **Ironic state is in an `emptyDir`.** A metal3 pod restart loses Ironic's database and the PXE binary until the CronJob restores it. The CronJob only recreates the pod when no BMH is mid-operation.
- **worker-1/2/3 are natively provisioned by default.** `externallyProvisioned` is omitted (so `false`). Syncing `okd-nodes` registers them and, once a MachineSet is scaled to 1, wipes the disk. gpu-1 stays `true`.
- **Untested on real hardware:** a full deprovision after the "Always continue boot" click, and whether PXE stays first in the boot order afterwards.

## Destructive Scaling Warning

Scaling a per-node MachineSet to 1 **power-cycles the physical host**. This is destructive for hosts that are live cluster members:

- `replicas: 1` → Machine controller claims the BMH → sets `spec.online: true` → host powers on
- `replicas: 0` (or deleting the Machine) → BMH sets `spec.online: false` → host powers off

For live nodes (like gpu-1), this means the node will be ejected from the cluster during scale-down. Workers 1-3 are only safe while their MachineSet is at 0. Scaling one to 1 **wipes and reinstalls** the host, so drain it first if it is a live node.

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
