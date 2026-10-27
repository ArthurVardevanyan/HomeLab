# MicroShift BootC

Builds a MicroShift BootC image with OS-level configs baked in (firewall, sysctl, cockpit) and MicroShift enabled as a host systemd service. Uses `bootc-image-builder` (BIB) to produce Anaconda-installer ISOs.

## Table of Contents

- [Quick Start](#quick-start)
- [ISO Workflow](#iso-workflow)
- [Build Modes](#build-modes)
- [Makefile Targets](#makefile-targets)
- [Architecture](#architecture)
- [Components](#components)
- [Pull from VM](#pull-from-vm)
- [Burn to Flash Drive](#burn-to-flash-drive)
- [MinisForum S100 UFS Support](#minisforum-s100-ufs-support)
- [Upgrading a Node](#upgrading-a-node)
- [Variables](#variables)
- [Troubleshooting](#troubleshooting)

## Quick Start

```bash
# Download RPMs and build image (release mode - fastest, ~2 min)
make image BUILD_MODE=release

# Build with local RPMs (from source, ~15-20 min)
make image BUILD_MODE=local

# Build and push to registry
make push BUILD_MODE=release

# Push with cache invalidation
PODMAN_OPTS="--no-cache" make push BUILD_MODE=release
```

## ISO Workflow

The `make iso` target uses `bootc-image-builder` to produce an Anaconda-installer ISO that burns to USB.

```bash
# Build image, push to registry, then build ISO
make iso BUILD_MODE=release
```

On boot, the ISO runs the Anaconda text installer with the embedded bootc image as the payload. Follow prompts, select install target, and reboot. The installed system is bootc-managed and upgradable via `bootc upgrade`.

- **ISO size**: ~1-2 GB (includes Anaconda environment + embedded bootc payload)
- **Build time**: ~5-30 min (depsolving installer package set over network)
- **Build prerequisites**: `--privileged` container, rootful podman store, /var/lib/containers/storage mounted, sudo

## Build Modes

| Mode      | Description                                       | Time      |
| --------- | ------------------------------------------------- | --------- |
| `release` | Downloads pre-built RPMs from GitHub releases     | ~2 min    |
| `copr`    | Downloads pre-built RPMs from COPR repository     | ~2 min    |
| `local`   | Builds RPMs from source (requires Go compilation) | 15-20 min |

## Makefile Targets

```bash
make fetch-sha      # Fetch latest base image SHA (caches locally)
make srpm           # Build SRPMs (clones upstream repo)
make rpm            # Build RPMs (depends on srpm)
make rpm-copr       # Download pre-built RPMs from COPR
make rpm-release    # Download pre-built RPMs from GitHub releases
make image          # Build BootC image (depends on rpm)
make push           # Push image to registry
make iso            # Build Anaconda-installer ISO with bootc-image-builder (uses iso)
make install-live   # Print bootc install command for Fedora Live USB (UFS hardware)
make clean          # Clean up build artifacts and temp clone
```

## Architecture

```text
┌─────────────────────────────────────────────────────┐
│  Builder Stage (quay.io/centos/centos:stream9-min) │
│  ─────────────────────────────────────────────────  │
│  1. Clone upstream microshift repo                   │
│  2. Download/copy RPMs (based on BUILD_MODE)       │
│  3. Prepare assets (release info, crio configs)    │
└─────────────────────────┬───────────────────────────┘
                          │ COPY --from=builder
                          ▼
┌─────────────────────────────────────────────────────┐
│  Final Stage (quay.io/centos-bootc/centos-bootc:st) │
│  ─────────────────────────────────────────────────  │
│  1. Install EPEL, createrepo_c, ca-certificates    │
│  2. Create local MicroShift repo + index it         │
│  3. Auto-detect MicroShift version from RPM name   │
│  4. Configure OpenShift mirror repo URL            │
│  5. Install microshift + microshift-networking     │
│     (OVN-K) + deps (cri-o, cri-tools,              │
│     openshift-clients, openvswitch3.4) and the      │
│     optional components (TopoLVM, OLM, Multus)      │
│  6. Cleanup caches and docs                        │
│  7. Copy helper scripts, enable microshift.service │
│  8. Write /etc/topolvm/lvmd.yaml, enable            │
│     microshift-lvm.service (loop-backed VG)         │
└─────────────────────────────────────────────────────┘
```

## Components

### Required (always installed)

- `microshift` — Core MicroShift package
- `microshift-release-info` — Release metadata
- `microshift-networking` — OVN-Kubernetes CNI (Kindnet is not used)
- `cri-o` — Container runtime
- `cri-tools` — CLI tools for CRI
- `openshift-clients` — oc CLI
- `openvswitch3.4` — Network virtualization

### Optional (controlled by flags)

| Flag           | Default | Package              |
| -------------- | ------- | -------------------- |
| `WITH_KINDNET` | 1       | unused (OVN-K stays) |
| `WITH_TOPOLVM` | 1       | `microshift-topolvm` |
| `WITH_OLM`     | 1       | `microshift-olm`     |
| `WITH_MULTUS`  | 1       | `microshift-multus`  |
| `COCKPIT`      | 0       | `cockpit`            |

### Storage (TopoLVM)

`microshift-topolvm` provides the default `topolvm-provisioner` StorageClass. It
needs an LVM volume group, `myvg1`, which `microshift-lvm.service` creates at
every boot, before `microshift.service`:

- A sparse backing file `/var/lib/microshift-okd/lvmdisk.image` of `LVM_VOLSIZE`
  (75G) is created if missing and attached to a loop device.
- The VG is created only when the device has no signature. An existing VG is just
  activated. The script refuses to reformat a device that has a signature but no VG.
- `/etc/topolvm/lvmd.yaml` (baked in the image) points the default device class at
  `myvg1`.

The size is only read when the file is first created. To resize later, grow the file
(`truncate -s <new> <file>`), `losetup -c <loop>`, then `pvresize <loop>`. To start over:
`systemctl stop microshift`, `lvremove -y myvg1`, `vgremove myvg1`, `losetup -D`,
`rm /var/lib/microshift-okd/lvmdisk.image`, then reboot.

## Pull from VM

After building the image on the VM, pull the ISO to your laptop:

```bash
# Pull microshift BootC image from VM to laptop
main.bash microshift-bootc-pull
```

This generates the following scp command (ISO only, build artifacts are not needed):

```bash
scp arthur@10.101.11.7:/home/arthur/Projects/HomeLab/containers/microshift-bootc/output/microshift.iso ./
```

## Burn to Flash Drive

Once the ISO is on your laptop:

```bash
# Using dd (most reliable, works on Linux/macOS)
sudo dd if=microshift.iso of=/dev/sdX bs=4M status=progress oflag=sync

# Or using cpimagewriter (Fedora)
cpimagewriter microshift.iso

# Or using balenaEtcher (GUI tool)
# balenaEtcher microshift.iso
```

## MinisForum S100 UFS Support

### Problem

The MinisForum S100 uses UFS (Universal Flash Storage) instead of traditional NVMe or SATA. Without UFS kernel modules in the initramfs, the system cannot boot from internal storage. Multiple Linux distributions (Ubuntu, Kubuntu 22.10/24.04, others) fail with:

```text
UUID=xxx does not exist. Dropping to a shell.
```

This happens because the UFS controller driver (`ufshcd`) is not loaded early enough in the boot process.

### References

- **Reddit thread (r/MiniPCs)**: <https://www.reddit.com/r/MiniPCs/comments/1eb8dgv/minisforum_s100_only_runs_windows_anyone_else/>
  - OP: u/Think-Fly765 (mass deleted)
  - Solution by community: Add `ufshcd` and `ufshcd-pci` modules to initramfs

- **AskUbuntu**: <https://askubuntu.com/questions/1446115/install-ubuntu-22-10-on-the-computer-with-ufs-universal-flash-storage-showing-t>

### Traditional Fix (Ubuntu/Debian)

For manual installations on Ubuntu/Debian-based systems:

```bash
# Boot from USB installer
# Mount root partition to /mnt
sudo mount /dev/mapper/ubuntu-vg-ubuntu-lv /mnt
sudo mount /dev/sda2 /mnt/boot  # if separate boot partition

# Bind mount virtual filesystems
sudo mount --bind /dev "$PWD/dev"
sudo mount --bind /proc "$PWD/proc"
sudo mount --bind /sys "$PWD/sys"

# Chroot
sudo chroot "$PWD" /bin/bash --login

# Add UFS modules to initramfs
echo "ufshcd" >> /etc/initramfs-tools/modules
echo "ufshcd-pci" >> /etc/initramfs-tools/modules

# Rebuild initramfs
update-initramfs -u -k all

# Exit and reboot
exit
sudo reboot
```

For LVM setups, mount both root AND boot partitions before chrooting.

**Limitations**: Does not work for full disk encryption (FDE), ZFS with FDE, or TPM-based FDE.

### BootC Solution (microshift-bootc)

#### Root cause (observed on the S100)

The CentOS Stream 10 kernel (and ELRepo `kernel-ml`) is built without UFS
(`# CONFIG_SCSI_UFSHCD is not set`), so no `ufshcd*` modules exist for it. The
Anaconda installer ISO uses the same kernel, so it cannot see the internal
disk at all. The Fedora Live kernel does ship UFS: the controller shows up in
`lspci` as `Alder Lake-N UFS Controller` (PCI `8086:54ff`) and the 128 GB disk
appears as `/dev/sda`.

A dracut drop-in alone (`add_drivers+="ufshcd ufshcd-pci"`) cannot work, because
there are no modules to include.

#### Fix: build the UFS modules into the image

`bootc.Containerfile` builds the modules out-of-tree against the exact kernel
in the image:

1. `os-base` stage runs `dnf -y update` once, so every later stage sees the
   same kernel.
2. `ufs-builder` stage runs `build-ufs-modules.sh`, which installs
   `kernel-devel-<kver>` (the distro's exact `.config`, `Module.symvers` and
   generated headers), downloads the matching kernel source RPM, extracts only
   `drivers/ufs` and `include/ufs`, and builds with
   `make -C /usr/src/kernels/<kver> M=<src>/drivers/ufs CONFIG_SCSI_UFSHCD=m ...`.
   The CentOS kernel has no devfreq/OPP; the driver compiles cleanly without
   them against these headers.
3. Final stage copies the `.ko` files to
   `/usr/lib/modules/<kver>/extra/ufs/`, runs `depmod`, writes
   `/usr/lib/dracut/dracut.conf.d/99-ufs.conf` and regenerates the image's
   initramfs with `dracut --no-hostonly`.

Build-time guards (any failure stops the build):

- `WITH_UFS` must be `0` or `1`; empty or other values fail rather than silently
  skipping. `make image` also checks the built image's initramfs for
  `ufshcd-core` and `ufshcd-pci`.
- `kernel-devel-<kver>` must exist for the image's exact kernel. There is no
  fallback to a regenerated config or a different kernel. If the mirror lags
  behind the base image's kernel, the build fails with a clear message; retry
  once it catches up.
- Each module's vermagic must equal the kernel version, and its
  `.gnu.linkonce.this_module` ELF section size must equal that of a stock module
  from the same kernel (the check the kernel makes when loading).

Build with `WITH_UFS=0` to skip all of this. Modules are **unsigned**, so Secure
Boot must be off (it is on the S100). Because the modules are rebuilt on every
image build, `bootc upgrade` keeps them in sync with whatever kernel the new
image carries.

Caveat: the kernel source RPM is fetched from `mirror.stream.centos.org`,
falling back to `composes.stream.centos.org`.

##### Past failure: `.gnu.linkonce.this_module section size must match`

The first working-looking build copied the kernel's `.config` out of
`/usr/lib/modules` and ran `make olddefconfig` in a source tree. The build
container had no `pahole`, so `CONFIG_DEBUG_INFO_BTF` turned itself off, which
in turn dropped `CONFIG_SCHED_CLASS_EXT` / `CONFIG_EXT_GROUP_SCHED`. Those
change `sizeof(struct module)`: our modules had a 0x540-byte `this_module`
section versus 0x580 in stock CentOS modules, so the kernel refused to load
them at boot even though the version string matched. Building against
`kernel-devel` avoids regenerating the config altogether.

#### Install workflow (Fedora Live + `bootc install`)

The Anaconda ISO still cannot see the disk (installer kernel has no UFS), so
install from a Fedora Live USB, whose kernel does:

1. Boot a Fedora Live USB on the S100.
2. Keep container storage in RAM. The live root is a small overlay and cannot
   hold the ~2.4 GB image. Mount tmpfs at the **default** paths so nothing else
   needs to change, then pull as root:

   ```bash
   sudo mkdir -p /var/lib/containers /var/tmp
   sudo mount -t tmpfs -o size=6G tmpfs /var/lib/containers
   sudo mount -t tmpfs -o size=2G tmpfs /var/tmp   # podman stages layers here
   sudo podman pull <registry>/homelab/microshift-bootc:<tag>
   ```

   tmpfs only consumes RAM as it fills. Always use `sudo`: rootless podman
   stores images under `~/.local/share/containers`, which `bootc` cannot see.

   The storage location and the `-v ...:/var/lib/containers` mount in the next
   step must point at the same place. If you use a custom root instead (for
   example `sudo podman --root /dev/shm/podman-ram ...`), pass `--root` to both
   the pull and the run, and mount `-v /dev/shm/podman-ram:/var/lib/containers`.
   Otherwise `bootc` sees an empty store. Note `/dev/shm` is capped at half of
   RAM by default.

3. Install the image straight to disk:

   ```bash
   sudo podman run --rm --privileged --pid=host --entrypoint bootc \
     -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
     --security-opt label=type:unconfined_t \
     <registry>/homelab/microshift-bootc:<tag> \
     install to-disk --wipe /dev/sda
   ```

   `make install-live` in `containers/microshift-bootc/` prints this command.
   `--entrypoint bootc` is required for images built before the image's
   `ENTRYPOINT` was removed; otherwise podman runs the old entrypoint script and
   hangs on "Waiting for MicroShift to start".

4. Reboot. The installed system boots with its own kernel, whose initramfs
   now contains the UFS modules.

#### Verify

Check the image contents:

```bash
podman run --rm --entrypoint bash localhost/microshift-bootc:latest -c '
  K=$(ls /usr/lib/modules)
  modinfo -k "$K" -F depends ufshcd-pci
  lsinitrd /usr/lib/modules/$K/initramfs.img | grep ufshcd'
```

Boot the image's own kernel and initramfs against an emulated UFS controller
(QEMU `-device ufs`, PCI `1b36:0013`, handled by `ufshcd-pci`). Extract with
`podman cp` from a `podman create`d container, then:

```bash
truncate -s 1G ufs.img
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -nographic -no-reboot \
  -kernel vmlinuz -initrd initramfs.img \
  -append "console=ttyS0 root=UUID=00000000-dead-beef-0000-000000000000 rd.timeout=15 loglevel=7" \
  -drive file=ufs.img,if=none,id=lu0,format=raw \
  -device ufs,id=ufs0 -device ufs-lu,drive=lu0,bus=ufs0,lun=0
```

Expect `scsi host2: ufshcd`, `sd 2:0:0:0: [sda] Attached SCSI disk` and no
`size must match` error. The dracut timeout waiting for the fake root UUID is
expected. QEMU's emulated controller logs some `dme-get ... failed` lines that
real hardware will not. This was run on the build host (QEMU from a Fedora
container with `--device /dev/kvm`); real S100 hardware is still the final test.

### Kernel Support Notes

- UFS host controller support is an in-tree driver (`drivers/ufs/`), not
  enabled in the CentOS Stream 10 kernel config.
- Modules involved: `ufshcd-core`, `ufshcd-pci`, `ufshcd-pltfrm`.

### UFS Troubleshooting

#### Verify modules are in initramfs

```bash
# After building the ISO and booting
lsinitrd /boot/initramfs-* | grep -i ufs
modprobe -l | grep ufs
```

#### Check UFS module availability

```bash
modinfo ufshcd
modinfo ufshcd-pci
```

#### Manual module loading (for recovery)

If modules aren't in initramfs but available on system:

```bash
# During initramfs emergency shell
modprobe ufshcd
modprobe ufshcd-pci
exit
```

## Upgrading a Node

Each push publishes two tags: a floating `<version>` tag and an immutable `<version>-<datetime>` tag. Install from and follow the **floating** tag. A node tracking a dated tag never sees new builds with `bootc upgrade`.

```bash
# One-time: point the node at the floating tag and reboot into it
sudo bootc switch --apply registry.arthurvardevanyan.com/homelab/microshift-bootc:<version>

# Afterwards
sudo bootc upgrade --apply
sudo bootc status    # Booted digest should match the registry
```

Image configuration lives in `/etc` or `/usr` so upgrades deliver it. Anything under `/var` or `/root` is only populated on first install, so the root kubeconfig symlink is created by a `tmpfiles.d` rule (`/usr/lib/tmpfiles.d/microshift-bootc.conf`), which also restores CRI-O's `policy.json` and `registries.d` if missing.

- **API server SANs**: `/etc/microshift/config.d/10-san.yaml`, generated from `DOMAIN` at build time (127.0.0.1/localhost are excluded — MicroShift rejects them in `subjectAltNames`).
- **Greenboot**: `/etc/greenboot/greenboot.conf` sets `MICROSHIFT_WAIT_TIMEOUT_SEC=1200` and `GREENBOOT_MAX_BOOT_ATTEMPTS=3`. A deployment that is not healthy after three boots is rolled back automatically.

## Variables

| Variable              | Default                                           | Description                                     |
| --------------------- | ------------------------------------------------- | ----------------------------------------------- |
| `BUILD_MODE`          | `local`                                           | RPM source mode: `local`, `copr`, or `release`  |
| `USHIFT_GITREF`       | `main`                                            | Git ref/branch/~~tag~~ for upstream repo        |
| ~~`BOOTC_IMAGE_TAG`~~ | auto-fetched                                      | Base image SHA override                         |
| `PUSH_REGISTRY`       | `~~registry~~.arthurvardevanyan.com`              | Target registry host                            |
| `PUSH_ORG`            | `homelab`                                         | Target registry org                             |
| `WITH_KINDNET`        | 1                                                 | Unused; the CNI stays OVN-Kubernetes            |
| `WITH_TOPOLVM`        | 1                                                 | Install TopoLVM storage                         |
| `WITH_OLM`            | 1                                                 | Install OLM operator lifecycle manager          |
| `WITH_MULTUS`         | 1                                                 | Install Multus CNI                              |
| `COCKPIT`             | 0                                                 | Enable Cockpit web console                      |
| `WITH_UFS`            | 1                                                 | Build UFS modules + initramfs (MinisForum S100) |
| `DOMAIN`              | `microshift.dc2.vardevanyan.com`                  | Domain for API server                           |
| `BIB_IMAGE`           | `quay.io/centos-bootc/bootc-image-builder:latest` | bootc-image-builder container image             |
| `BIB_OUT`             | `./output/bib-out`                                | Temporary build directory for ISO               |

## Troubleshooting

### Version detection fails

The script auto-detects MicroShift version from the RPM filename to build the OpenShift mirror URL. If this fails, it defaults to version `4.21`.

### Dependency resolution errors

Ensure `BUILD_MODE` matches the RPM source. `release` mode uses GitHub releases which already include all required RPMs.

### Build cache issues

Use `PODMAN_OPTS="--no-cache"` to force a fresh build:

```bash
PODMAN_OPTS="--no-cache" make image BUILD_MODE=release
```

### Node stays on the old image (greenboot fallback)

Symptom: `bootc switch`/`upgrade` succeeds and `ostree admin status` shows the new deployment as `(pending)`, but every reboot comes back on the old one.

Cause: greenboot's boot counter ran out (the previous deployment failed MicroShift health checks, e.g. missing CRI-O `policy.json`), and GRUB is pinned to the rollback entry (`set default=1`).

```bash
grub2-editenv list    # boot_success=0 and boot_counter=-1 confirms it
grep -o 'ostree=[^ ]*' /proc/cmdline

# Clear it (/boot is read-only; the remount may report "busy", which is harmless)
sudo mount -o remount,rw /boot
sudo grub2-editenv - unset boot_counter
sudo grub2-editenv - set boot_success=1
sudo systemctl reboot
```

If the new image also fails its health check, it will count down and fall back again. Check `journalctl -b -u greenboot-healthcheck` and `journalctl -b -u microshift` before the attempts run out.

### CRI-O: no policy.json file found

Pods stuck with `no policy.json file found at ... /etc/containers/policy.json`. The el9 CRI-O only looks in `/etc/containers`, while CentOS 10 ships the file in `/usr/share/containers`. The image build copies it and fails if it is missing. If you see this on a node, it is running an image built before that fix (see `sudo bootc status`).

### ISO build fails with SELinux denials

The `make iso` target requires `--privileged` container and rootful podman store.
If you encounter SELinux AVC denials on the `:z` bind mount, add `--security-opt label=disable`
to the podman run command in the `iso:` target, or run `sudo setenforce 0` temporarily.

### Anaconda installer does not find the bootc payload

The ISO embeds the bootc image as a payload in the Anaconda installer. On boot, the ISO
runs the Anaconda text installer which consumes the bootc image and installs it to disk.
If the installer reports "bootc image not found", ensure the ISO was built successfully
and the `BOOTC_IMAGE_TAG` variable is set correctly.
