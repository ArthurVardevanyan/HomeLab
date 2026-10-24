# Loose Reverse Path Filter

Sets `net.ipv4.conf.all.rp_filter=2` on control plane nodes so that metal3 provisioning traffic is not dropped.

## Table of Contents

- [Loose Reverse Path Filter](#loose-reverse-path-filter)
  - [Table of Contents](#table-of-contents)
  - [Purpose](#purpose)
  - [Resources](#resources)
  - [Verify](#verify)
  - [Notes](#notes)

## Purpose

The metal3 pod runs on a master and listens on the provisioning IP on `prov-shim` (VLAN 11). The hosts being provisioned are on `10.101.10.0/24`, whose return route is `br-ex`. With the OS default of `rp_filter=1` the kernel drops that asymmetric traffic, which breaks DHCP, iPXE and Ironic callbacks.

The effective value is the higher of `all` and the per-interface value. Setting `all` covers interfaces that nmstate recreates (`br4.11`, `prov-shim`), which reset to 1 on their own.

## Resources

| File         | Type     | What it sets                      | When applied               |
| ------------ | -------- | --------------------------------- | -------------------------- |
| `tuned.yaml` | TuneD CR | `net.ipv4.conf.all.rp_filter = 2` | Runtime (via TuneD daemon) |

## Verify

```bash
kubectl -n openshift-cluster-node-tuning-operator get profile
# Expected: server-1, server-2 and server-3 use rp-filter-loose

oc debug node/server-1 -- chroot /host sysctl net.ipv4.conf.all.rp_filter
# Expected: net.ipv4.conf.all.rp_filter = 2
```

## Notes

- No reboot is needed, unlike a MachineConfig.
- Priority 20 beats the built-in `openshift-control-plane` profile (30). The profile includes it, so nothing else changes.
- Only masters need it. Workers never run metal3.
