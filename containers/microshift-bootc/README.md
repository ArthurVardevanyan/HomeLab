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
│  5. Install microshift + deps (cri-o, cri-tools,   │
│     openshift-clients, openvswitch3.4)             │
│  6. Install optional components (Kindnet, TopoLVM,  │
│     OLM, Multus)                                    │
│  7. Cleanup caches and docs                        │
│  8. Copy helper scripts, enable microshift.service │
│  9. Set up LVM/MicroShift directories              │
└─────────────────────────────────────────────────────┘
```

## Components

### Required (always installed)

- `microshift` — Core MicroShift package
- `microshift-release-info` — Release metadata
- `cri-o` — Container runtime
- `cri-tools` — CLI tools for CRI
- `openshift-clients` — oc CLI
- `openvswitch3.4` — Network virtualization

### Optional (controlled by flags)

| Flag           | Default | Package              |
| -------------- | ------- | -------------------- |
| `WITH_KINDNET` | 1       | `microshift-kindnet` |
| `WITH_TOPOLVM` | 1       | `microshift-topolvm` |
| `WITH_OLM`     | 1       | `microshift-olm`     |
| `WITH_MULTUS`  | 1       | `microshift-multus`  |
| `COCKPIT`      | 0       | `cockpit`            |

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

## Variables

| Variable              | Default                                           | Description                                     |
| --------------------- | ------------------------------------------------- | ----------------------------------------------- |
| `BUILD_MODE`          | `local`                                           | RPM source mode: `local`, `copr`, or `release`  |
| `USHIFT_GITREF`       | `main`                                            | Git ref/branch/~~tag~~ for upstream repo        |
| ~~`BOOTC_IMAGE_TAG`~~ | auto-fetched                                      | Base image SHA override                         |
| `PUSH_REGISTRY`       | `~~registry~~.arthurvardevanyan.com`              | Target registry host                            |
| `PUSH_ORG`            | `homelab`                                         | Target registry org                             |
| `WITH_KINDNET`        | 1                                                 | Install Kindnet CNI                             |
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

### ISO build fails with SELinux denials

The `make iso` target requires `--privileged` container and rootful podman store.
If you encounter SELinux AVC denials on the `:z` bind mount, add `--security-opt label=disable`
to the podman run command in the `iso:` target, or run `sudo setenforce 0` temporarily.

### Anaconda installer does not find the bootc payload

The ISO embeds the bootc image as a payload in the Anaconda installer. On boot, the ISO
runs the Anaconda text installer which consumes the bootc image and installs it to disk.
If the installer reports "bootc image not found", ensure the ISO was built successfully
and the `BOOTC_IMAGE_TAG` variable is set correctly.
