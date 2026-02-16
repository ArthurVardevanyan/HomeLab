# Technitium DNS Server

Technitium DNS Server is an open source authoritative as well as recursive DNS server for self-hosting DNS with privacy & security. It provides ad & malware blocking at the DNS level, a web-based admin console, and supports DNS-over-TLS, DNS-over-HTTPS, and DNS-over-QUIC.

## Ports

| Port | Protocol | Description        |
| ---- | -------- | ------------------ |
| 53   | TCP/UDP  | DNS Service        |
| 5380 | TCP      | Web Console (HTTP) |

## Overlays

| Overlay    | Description                                                                             |
| ---------- | --------------------------------------------------------------------------------------- |
| okd        | OKD cluster with Gateway API, Velero backup, VPA, Prometheus Probe, kube-vip on VLAN 11 |
| microshift | MicroShift with topolvm storage, Kubernetes Ingress, kube-vip on VLAN 11                |

## Notes

- External DNS support is not yet added; DNS records are managed manually.
- Local DNS records are being pulled from the UniFi UDM SE.

## TODO

- External DNS Support
- Technitium Prometheus Exporter
  - <https://github.com/Work-m8/technitium-prometheus-exporter>
  - <https://github.com/guycalledseven/technitium-dns-prometheus-exporter>
  - <https://github.com/brioche-works/technitium-dns-prometheus-exporter>

## Links

- [Technitium DNS Server](https://technitium.com/dns/)
- [Docker Hub](https://hub.docker.com/r/technitium/dns-server)
- [GitHub](https://github.com/TechnitiumSoftware/DnsServer)
- [Docker Environment Variables](https://github.com/TechnitiumSoftware/DnsServer/blob/master/DockerEnvironmentVariables.md)
