# Metal3 Network Tuning

Tunes `rp_filter` and `arp_ignore` on control plane nodes so metal3 provisioning traffic is neither dropped nor misrouted. The resource keeps its original name, `rp-filter-loose`.

## Table of Contents

- [Metal3 Network Tuning](#metal3-network-tuning)
  - [Table of Contents](#table-of-contents)
  - [Purpose](#purpose)
  - [Resources](#resources)
  - [Verify](#verify)
  - [Notes](#notes)

## Purpose

The metal3 pod runs on a master and listens on the provisioning IP on `prov-shim` (VLAN 11). The hosts being provisioned are on `10.101.10.0/24`, whose return route is `br-ex`. With the OS default of `rp_filter=1` the kernel drops that asymmetric traffic, which breaks DHCP, iPXE and Ironic callbacks.

The effective value is the higher of `all` and the per-interface value. Setting `all` covers interfaces that nmstate recreates (`br4.11`, `prov-shim`), which reset to 1 on their own.

`arp_ignore` fixes the second half of the same path. `br4.11` (the VLAN 11 bridge, `.49`) and `prov-shim` (`10.101.11.250`) are both on VLAN 11. With the default of `0` the kernel answers an ARP request for `10.101.11.250` on both interfaces, and the `br4.11` reply is faster, so the router caches `br4.11`'s MAC. The TFTP request then arrives on `br4.11`; dnsmasq runs with `bind-dynamic` and `interface=prov-shim` and silently drops it. The symptom is a PXE TFTP timeout while HTTP `:6180` on the same IP still answers, because httpd listens on all interfaces. With `1` only `prov-shim` replies, because only it owns the address.

## Resources

| File         | Type     | What it sets                                           | When applied               |
| ------------ | -------- | ------------------------------------------------------ | -------------------------- |
| `tuned.yaml` | TuneD CR | `net.ipv4.conf.all.rp_filter = 2` and `arp_ignore = 1` | Runtime (via TuneD daemon) |

## Verify

```bash
kubectl -n openshift-cluster-node-tuning-operator get profile
# Expected: server-1, server-2 and server-3 use rp-filter-loose

oc debug node/server-1 -- chroot /host sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.all.arp_ignore
# Expected: rp_filter = 2, arp_ignore = 1

# Only the prov-shim MAC may answer for the provisioning IP. Find it with:
#   kubectl -n openshift-machine-api exec <metal3 pod> -c metal3-dnsmasq -- \
#     ip -br link show prov-shim
arping -c 3 -I br11 10.101.11.250     # run on the UDM
```

## Notes

- No reboot is needed, unlike a MachineConfig.
- Priority 20 beats the built-in `openshift-control-plane` profile (30). The profile includes it, so nothing else changes.
- Only masters need it. Workers never run metal3.
- `arp_ignore=1` is safe on this host: every address on the masters, including the `br-ex` API VIP and `ceph-pub-shim`, is answered by the interface that receives the request. `arping` from the UDM shows one reply per address instead of two.
