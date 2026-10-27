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

## Hardware Notes

### MinisForum S100 UFS Support

The MinisForum S100 uses UFS (Universal Flash Storage) instead of NVMe/SATA, and the CentOS Stream 10 kernel is built without UFS support. The image build therefore compiles `ufshcd-core`, `ufshcd-pci` and `ufshcd-pltfrm` against the image's exact kernel using the distro's `kernel-devel` package (`build-ufs-modules.sh`), and fails the build if a module's layout differs from the kernel's, installs them, and regenerates the initramfs. Set `WITH_UFS=0` to skip. The modules are unsigned, so Secure Boot must be disabled.

The Anaconda ISO cannot see the disk either, so install from a Fedora Live USB with `make install-live`, which prints the commands: mount tmpfs for container storage (the live root is too small for the image), `podman pull`, then `bootc install to-disk`. `STORE_SIZE` (default `6G`) sets the tmpfs size.

For more details, see [MinisForum S100 UFS Support](../../notes/minisforum-s100-ufssupport.md).

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
