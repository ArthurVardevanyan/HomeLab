# metal3 PXE

Custom iPXE binary and CronJob that let metal3/Ironic provision the Minisforum workers (and later the GPU node) over PXE on the `10.101.10.0/24` network.

## Table of Contents

- [metal3 PXE](#metal3-pxe)
  - [Table of Contents](#table-of-contents)
  - [Why This Exists](#why-this-exists)
  - [Boot Flow](#boot-flow)
  - [Files](#files)
  - [The CronJob](#the-cronjob)
  - [Rebuilding the EFI Binary](#rebuilding-the-efi-binary)
  - [Verify](#verify)
  - [Known Issue: Boot Option Restoration Loop](#known-issue-boot-option-restoration-loop)
  - [Gotchas](#gotchas)

## Why This Exists

- The router (UDM) hands out one fixed DHCP boot filename (Option 67) and cannot vary it per client. The stock metal3 flow expects different files for different hosts, so hosts looped.
- The workers use RTL8125 NICs, which iPXE has no native driver for. The `snponly.efi` build uses the UEFI firmware's own network stack instead.
- So the binary has an iPXE script embedded in it. It runs DHCP itself and chains straight to the metal3 HTTP server, ignoring Option 67.
- metal3 keeps `/shared/tftpboot` in an `emptyDir`, so the binary must be put back whenever the pod is recreated. That is the CronJob's job.

## Boot Flow

1. The host PXE boots and fetches `snponly-homelab.efi` from the metal3 pod (dnsmasq TFTP, served from `/shared/tftpboot`).
2. The embedded script ([embed.ipxe](embed.ipxe)) runs `dhcp`, then for each NIC chains `http://10.101.11.250:6180/pxelinux.cfg/<mac-with-hyphens>`.
3. Ironic writes that per-MAC file (a symlink to `<node-uuid>/config`):
   - **During deploy or clean:** it loads the Ironic Python Agent (IPA) kernel and ramdisk.
   - **After a finished deploy:** it contains only `sanboot --no-describe || exit 0`, which should boot the local disk.
4. If the per-MAC script returns, the embedded script runs `exit 1` so the UEFI boot manager tries the next boot option (the installed OS on NVMe). If no per-MAC file exists (HTTP 404) it also runs `exit 1`.

There is deliberately **no fallback to `inspector.ipxe`**. metal3's stock `boot.ipxe` has one, and it would PXE boot the agent again instead of the installed OS.

`exit 0` was tried earlier and a PXE loop was seen, but that loop is explained by the shim fallback described under Known Issue, so the effect of `exit 0` is unconfirmed.

## Files

| File                      | Purpose                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| `embed.ipxe`              | Script embedded in the EFI binary (see Boot Flow)                                                |
| `build.sh`                | Builds `snponly-homelab.efi` from upstream iPXE in a Fedora container and writes the `.b64` file |
| `snponly-homelab.efi.b64` | The binary as base64 text. The CI large-file check rejects binaries inside kustomize apps        |
| `cronjob.yaml`            | ServiceAccount, Role, RoleBinding and the `metal3-pxe-sync` CronJob                              |
| `../kustomization.yaml`   | `configMapGenerator` builds `metal3-pxe-assets` from the `.b64` file; its hash changes with it   |

## The CronJob

`metal3-pxe-sync` runs every 10 minutes in `openshift-machine-api` (`concurrencyPolicy: Forbid`). It uses `kubectl exec` into the `metal3-httpd` container of the running metal3 pod and does three things:

1. **Install the EFI.** Compares the sha256 of `/shared/tftpboot/snponly-homelab.efi` against the ConfigMap's copy and rewrites it (temp file, then `mv`) if they differ.
2. **Repair dangling image aliases.** metal3 generates links such as `ironic-python-agent.rootfs -> coreos10-unknown-rootfs.img` that point at a file named `…x86_64…`. The job re-links `unknown` to `x86_64` when the fixed target exists.
3. **Self-heal Ignition.** If Ironic started while the alias was dangling, its `ironic.conf` lacks `ignition.firstboot` and the agent boots without Ignition. When the alias now resolves and the config lacks it, the job deletes the metal3 pod so it regenerates. It only does this when:
   - the pod is at least 180 seconds old, and
   - no BareMetalHost is `inspecting`, `preparing`, `provisioning` or `deprovisioning`, because Ironic's database is also an `emptyDir` and a restart loses in-flight state.

Trigger a run immediately instead of waiting:

```bash
export KUBECONFIG=$HOME/.kube/okd
kubectl -n openshift-machine-api create job --from=cronjob/metal3-pxe-sync pxe-sync-manual
kubectl -n openshift-machine-api logs job/pxe-sync-manual
```

## Rebuilding the EFI Binary

Needs `podman` and network access.

```bash
okd/okd-nodes/base/metal3-pxe/build.sh
```

Then commit `snponly-homelab.efi.b64`. The ConfigMap name gets a new hash suffix, ArgoCD rolls it out, and the CronJob installs it within 10 minutes (or run the job manually, as above).

The raw `.efi` is deleted by the script on purpose. Do not commit it.

## Verify

```bash
export KUBECONFIG=$HOME/.kube/okd
NS=openshift-machine-api
P=$(kubectl -n $NS get pods -l k8s-app=metal3 --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# The binary the pod serves must match the repo
kubectl -n $NS exec $P -c metal3-httpd -- sha256sum /shared/tftpboot/snponly-homelab.efi
base64 -d okd/okd-nodes/base/metal3-pxe/snponly-homelab.efi.b64 | sha256sum

# Watch a host boot
kubectl -n $NS logs $P -c metal3-dnsmasq -f | grep -E "sent|not found"
kubectl -n $NS logs $P -c metal3-httpd -f | grep -E "pxelinux.cfg|deploy_(kernel|ramdisk)"
```

Expected on a healthy deploy:

- One `pxelinux.cfg/<mac>` request returning 200, then `deploy_kernel`, `deploy_ramdisk` and `ironic-python-agent.rootfs` downloads.
- After the install, a single `pxelinux.cfg/<mac>` request and then the host comes up on its own disk (ping on its `10.101.10.x` address).

The log line `file /shared/tftpboot/autoexec.ipxe not found` is normal and harmless. iPXE always looks for it first.

## Known Issue: Boot Option Restoration Loop

**Status: worked around by hand, not automated.** After a finished install the host cycles through PXE roughly every 22 seconds and never reaches the OS, until "Always continue boot" is selected once on its console.

The "Boot Option Restoration" screen is **not a BIOS feature**. It comes from shim's fallback loader (`\EFI\BOOT\fbx64.efi`, source: [rhboot/shim `fallback.c`](https://github.com/rhboot/shim/blob/main/fallback.c)).

Why the loop happens:

1. After install Ironic leaves `sanboot --no-describe || exit 0` in the per-MAC config. `sanboot` starts the disk's removable-media path `\EFI\BOOT\BOOTX64.EFI`, which is shim.
2. Shim run from that path starts `fbx64.efi`, which reads `\EFI\centos\BOOTX64.CSV` and creates or reorders the `centos` NVRAM boot entry.
3. On a machine with a TPM the fallback then **resets the system** so the firmware picks up the new entry (countdown title "Boot Option Restoration", message "Press any key to stop system reset").
4. PXE is still first, so the host PXE boots again and the cycle repeats.

`sanboot` does not return, so the `exit 1` in `embed.ipxe` is not what ends this loop. It still matters when no per-MAC config exists or the script returns.

The fix is to choose **Always continue boot** on the console once per host. That sets the NVRAM variable `FB_NO_REBOOT` (GUID `605dab50-e046-4300-abb6-3dd810dd8b23`) to `1`. The fallback then starts the installed OS directly. Check it from a running host:

```bash
sudo od -An -tx1 /sys/firmware/efi/efivars/FB_NO_REBOOT-605dab50-e046-4300-abb6-3dd810dd8b23
# Set:  07 00 00 00 01 00 00 00   (4 attribute bytes, then 01)
sudo efibootmgr
```

Observed state (2026-10-24):

| Host     | `FB_NO_REBOOT` | Notes                                                   |
| -------- | -------------- | ------------------------------------------------------- |
| worker-2 | 1              | Boots through PXE entry `0005`, `centos` first in order |
| worker-3 | 1              | Same                                                    |
| worker-1 | not checked    | Still looping when last checked (not yet clicked)       |

Does it survive deprovision and reprovision?

- It lives in firmware NVRAM, not on the disk, so cleaning and reinstalling do not remove it. After a reinstall the new ESP gets a new `centos` entry (new partition GUID) and the old entry is left behind, which is harmless.
- It is lost if the NVRAM is cleared: a CMOS reset, loading BIOS defaults or a BIOS update may do this. Which of them do on these boards has not been tested.
- A replaced board needs the click again. Nothing in this repo sets it.

`PXE` must stay first in the BIOS boot order. Putting the disk first would break teardown, because cleaning needs the host to PXE into the agent. After the install, `centos` is first in `BootOrder` but the hosts still booted via the PXE entry (`BootCurrent: 0005`), including repeated boots on worker-2. That is only a couple of samples, and a deprovision has not been tested yet.

Not tried yet, as alternatives to clicking by hand:

- Disable the fTPM in the BIOS. Per the shim source the fallback only resets when a TPM is present. Not verified on these boards, and it removes the TPM for the node.
- Set `FB_NO_REBOOT` from the OS on first boot (MachineConfig or Ignition). Untested.
- Make the per-MAC boot not go through `\EFI\BOOT\BOOTX64.EFI`. Ironic generates that script, so this needs a change on its side.

The earlier note that `exit 0` made things loop was probably this same fallback reset. It was not isolated, so treat it as unconfirmed.

## Gotchas

- **Lost on pod restart.** If the metal3 pod is recreated the EFI is gone until the next CronJob run (up to 10 minutes). Hosts that PXE in that window get the stock binary.
- **ArgoCD must have the files.** The cluster's `okd-nodes` Application syncs from the git remote. If `metal3-pxe/` is not pushed there, no CronJob or ConfigMap exists and the EFI only stays in the pod because it was copied by hand.
- **Root device.** With `inspectionMode: disabled`, BMO defaults the root device hint to `/dev/sda`, which fails with `DeviceNotFound`. The BMHs set `rootDeviceHints.deviceName: /dev/nvme0n1` (the only disk in all four hosts).
- **Hint changes mid-deploy are ignored.** Ironic does not pick up a changed BMH hint during a deploy. Fix the BMH first, then restart provisioning.
- **Ironic state is ephemeral.** Ironic's database is an `emptyDir`, so BMH status (including `status.hardware.nics`) can be lost when metal3 restarts. See the BMH status patching section in [../../README.md](../../README.md).
