# GPU Kernel Args + NIC Power Management Fix

## Overview

This component provides two things:

1. **GPU kernel arguments** (`mc.yaml`) — `iommu=pt`, `pcie_aspm=force`, `pcie_aspm.policy=powersave`
2. **Realtek NIC power management fix** (`98-nic-pm-fix.yaml`) — disables EEE and clkpm on Realtek RTL8125 controllers

## NIC Fix Design

### Why a single component for GPU + worker nodes

The worker nodes (MS-A1-A5870) and the GPU node (R5-3600) share the same NIC chip: **Realtek RTL8125** (PCI vendor `0x10ec`, device `0x8125`). The root cause of the auto-negotiation link drops is the same — EEE and PCIe clkpm/L1-ASPM power management enabled by default on this controller.

Rather than maintaining separate fixes per node role, we use a **single MachineConfig** labeled `role: worker`. This is picked up by:

- The **worker MCP** (nodeSelector: `worker`) — applies to all 3 workers
- The **gpu MCP** (machineConfigSelector: `worker` + `gpu`) — applies to the GPU node

### Why not scope by node label?

Scoping the MC by a custom label (e.g., `homelab/realtek-nic: "true"`) would require:

- Adding labels to nodes or machinesets
- Managing label lifecycle (add on provision, remove on NIC replacement)
- More files to maintain

Instead, the fix is **inherently scoped by hardware**:

1. **udev rule** matches only PCI vendor `0x10ec` and device `0x8125` — fires on no other NICs
2. **systemd unit** uses `ExecStart-=` (dash prefix = ignore failure) — ethtool on a non-existent interface is harmless

The result is the same: the fix only affects nodes with Realtek RTL8125 NICs, without needing any labels.

### What it does

The fix operates at two layers:

- **udev rule** — Matches PCI vendor `0x10ec` and device `0x8125`. Sets `clkpm=0`, `l1_aspm=0`, `power/control=on` on the Realtek NIC's PCI device. Fires only on Realtek NICs (no other NICs match).

- **systemd unit** — Fires before `network-pre.target`. Runs `ethtool --set-eee` on enp3s0, enp4s0 (workers) and enp42s0 (GPU node). Uses `ExecStart-=` to ignore failure if an interface does not exist on a given node.

### Interface names by node

- **worker-1**: enp3s0, enp4s0 — RTL8125 (2 bonded)
- **worker-2**: enp3s0, enp4s0 — RTL8125 (2 bonded)
- **worker-3**: enp3s0, enp4s0 — RTL8125 (2 bonded)
- **gpu-1**: enp42s0 — RTL8125 (single)

All four nodes carry the same chip, so a single ethtool command set covers them all.
