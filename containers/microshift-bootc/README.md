# MicroShift BootC

Builds a MicroShift BootC image with OS-level configs baked in (firewall, sysctl, cockpit) and a custom entrypoint with image SHA detection and DNS validation.

## Table of Contents

- [Quick Start](#quick-start)
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
make iso            # Create a bootable ISO from the image
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
│  8. Copy entrypoint scripts + systemd service      │
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

After building the image on the VM, pull it to your laptop:

```bash
# Pull microshift BootC image from VM to laptop
main.bash microshift-bootc-pull
```

This generates the following scp command:

```bash
scp -r arthur@10.101.11.7:/home/arthur/Projects/HomeLab/containers/microshift-bootc/output/ ./
```

## Variables

| Variable          | Default                          | Description                                    |
| ----------------- | -------------------------------- | ---------------------------------------------- |
| `BUILD_MODE`      | `local`                          | RPM source mode: `local`, `copr`, or `release` |
| `USHIFT_GITREF`   | `main`                           | Git ref/branch/tag for upstream repo           |
| `BOOTC_IMAGE_TAG` | auto-fetched                     | Base image SHA override                        |
| `PUSH_REGISTRY`   | `registry.arthurvardevanyan.com` | Target registry host                           |
| `PUSH_ORG`        | `homelab`                        | Target registry org                            |
| `WITH_KINDNET`    | 1                                | Install Kindnet CNI                            |
| `WITH_TOPOLVM`    | 1                                | Install TopoLVM storage                        |
| `WITH_OLM`        | 1                                | Install OLM operator lifecycle manager         |
| `WITH_MULTUS`     | 1                                | Install Multus CNI                             |
| `COCKPIT`         | 0                                | Enable Cockpit web console                     |
| `DOMAIN`          | `microshift.dc2.vardevanyan.com` | Domain for API server                          |

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
