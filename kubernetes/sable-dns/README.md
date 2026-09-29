# Sable DNS

Sable is a single-binary, high-performance DNS server that replaces Technitium
as the homelab DNS backend. It serves authoritative + recursive (forwarding)
DNS with ad/malware blocking, a web admin console, and DNS-over-HTTPS, and
keeps all state (zones, blocklists, settings) in a SQLite database on a PVC.

## Table of Contents

- [Sable DNS](#sable-dns)
  - [Table of Contents](#table-of-contents)
  - [Why Sable](#why-sable)
  - [Ports](#ports)
  - [Configuration Seed](#configuration-seed)
  - [Overlays](#overlays)
  - [Cutover (Technitium to Sable)](#cutover-technitium-to-sable)
  - [Rollback](#rollback)
  - [Notes](#notes)
  - [Links](#links)

## Why Sable

Technitium is being retired in favor of Sable. The new `sabledns.io` entry
mirrors the old `technitium.*` layout and reuses the same load-balancer IPs
(`10.101.1.4` MicroShift/kube-vip, `10.101.9.254` OKD/MetalLB). Sable is
deployed in parallel to Technitium; you cut over by scaling Technitium down and
Sable up. The Technitium manifests stay in place until you clean them up.

## Ports

| Port  | Protocol | Description                                           |
| ----- | -------- | ----------------------------------------------------- |
| 53    | TCP/UDP  | DNS (LB port; Sable listens on container port `8053`) |
| 5380  | TCP      | Web console (HTTP)                                    |
| 53443 | TCP      | DNS-over-HTTPS + HTTPS console                        |

## Configuration Seed

Sable is configured with a strict TOML file at `/data/sable.toml` (on the PVC).
The `sable-dns-config` ConfigMap holds a first-boot seed, and an init container
copies it into the PVC **only if it does not already exist**. After that,
Sable owns the file and rewrites it when you change settings in the console, so
console changes persist across restarts. To change the seed you must wipe the
`/data` PVC (fresh start) or edit the running file via the console.

The seed sets the DNS listeners, forwards to the internal forwarder
(`10.101.10.1`, same as Technitium), enables blocking + query logging, and
serves DoH on `53443` using the cert-manager-issued certificate. Authoritative
zones and the admin account are **not** in the TOML — they are imported into
Sable's database during first-run setup (see Cutover).

## Overlays

| Overlay    | Description                                                                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| okd        | OKD cluster: Gateway API HTTPRoute, UniFi DNSEndpoint, Velero backup, VPA, Prometheus Probe. MetalLB LB is defined but commented out (standby). |
| microshift | MicroShift: topolvm storage, Kubernetes Ingress, kube-vip LB on `10.101.1.4`.                                                                   |

Hostnames: `sabledns.io` (console, apex) and `dns.sabledns.io` (DNS) are served
by the MicroShift cluster; `okd.sabledns.io` / `okd.dns.sabledns.io` are the
OKD-cluster equivalents. The OKD cluster's `external-dns` (UniFi provider)
publishes all `sabledns.io` internal records from the `okd` overlay DNSEndpoint.

## Cutover (Technitium to Sable)

The Sable ArgoCD apps are registered but **not** synced (manual sync), and
Technitium is still the live DNS. Because both use the same LB IPs, they cannot
both bind the load balancer at once — there is a brief DNS gap during the flip
(do it in a low-traffic window). Work per cluster:

1. **Export Technitium state first** (before touching the cluster): from the
   Technitium console, export every zone and take a full Technitium backup.
   Sable stores zones in its own SQLite DB, so this export is the import source.
2. **Scale Technitium down** and **free the LB IP** (scaling to 0 alone does
   not release the IP — the LoadBalancer service keeps it):
   - MicroShift (`10.101.1.4`):

     ```bash
     export KUBECONFIG=$HOME/.kube/microshift
     kubectl -n technitium-dns scale statefulset/technitium-dns --replicas=0
     kubectl -n technitium-dns delete svc technitium-dns-udp-vlan1
     ```

   - OKD: `kubectl -n technitium-dns scale statefulset/technitium-dns --replicas=0`
     (its MetalLB service is not active, so `10.101.9.254` is already free).
     Confirm the IP is released (MetalLB/kube-vip) before continuing.
     The apps are manual-sync, so ArgoCD will not re-create what you delete — just
     don't re-sync Technitium while Sable holds the IPs.
3. **Deploy Sable:** in ArgoCD, sync `sable-dns` (OKD) and
   `sable-dns-microshift` (MicroShift). The pods start from the pre-seeded
   `sable.toml` and rebind the LB IP.
4. **First-run setup (console/API):** open the Sable console
   (`https://sabledns.io/` on MicroShift, `https://okd.sabledns.io/` on OKD).
   Every route redirects to `/setup` until you create the initial administrator.
   Then **import the Technitium zones** into Sable and recreate any blocking
   (blocklist) policy.
5. **Verify:** `dig @10.101.1.4 <name>` / `dig @10.101.9.254 <name>` for a SOA,
   an A record, a PTR, and a blocked name; confirm the console loads.
6. **Cut clients over:** point resolvers at `dns.sabledns.io` /
   `okd.dns.sabledns.io` and repoint the public `sabledns.io` domain at the home
   address.

To also expose OKD DNS on the load balancer, uncomment `./service.yaml` in
`overlays/okd/kustomization.yaml` (it is defined but inactive, matching
Technitium).

## Rollback

Technitium stays in the repo, so rolling back is just reversing the flip:

1. **Free the Sable IP(s)** (per cluster, mirror of step 2 above):
   - MicroShift: `kubectl -n sable-dns scale statefulset/sable-dns --replicas=0`
     then `kubectl -n sable-dns delete svc sable-dns-udp-vlan1`.
   - OKD: scale `sable-dns` to 0 (no active LB service to remove).
2. **Bring Technitium back:** re-sync the `technitium-dns` /
   `technitium-dns-microshift` ArgoCD apps (re-creates the LB services and pods)
   and restore the Technitium backup if you made changes to Sable.

## Notes

- Sable runs as **nonroot (uid 65532)**; the pod sets `runAsUser`/`runAsGroup`/
  `fsGroup: 65532` so it can create and write its SQLite DB, key, and config on
  the Rook (`rook-ceph-block`) / topolvm PVC. The init container runs as the
  same user so the seeded file is owned by Sable.
- Forwarding is to the internal forwarder `10.101.10.1` (same as Technitium);
  client recursion is restricted to private sources.
- The OKD `EgressFirewall` mirrors Technitium's allow-list. If you enable
  **remote** blocklist subscriptions in Sable, add those hosts to the firewall.
- **Cleanup (later):** once Sable is confirmed, delete the `technitium-dns` /
  `technitium-dns-microshift` ArgoCD apps, `kubernetes/technitium-dns/`, and the
  `technitium.*` DNS records.

## Links

- [Sable](https://sabledns.io)
- [GitHub](https://github.com/drudge/sable)
- [Technitium migration guide](https://sabledns.io/docs/guides/technitium-migration.md)
- Image: `ghcr.io/drudge/sable` (pinned `1.3.1`)
