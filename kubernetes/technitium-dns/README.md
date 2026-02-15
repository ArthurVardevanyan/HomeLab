# Technitium DNS Server

Technitium DNS Server is an open source authoritative as well as recursive DNS server for self-hosting DNS with privacy & security. It provides ad & malware blocking at the DNS level, a web-based admin console, and supports DNS-over-TLS, DNS-over-HTTPS, and DNS-over-QUIC.

## Ports

| Port | Protocol | Description        |
| ---- | -------- | ------------------ |
| 53   | TCP/UDP  | DNS Service        |
| 5380 | TCP      | Web Console (HTTP) |

## Overlays

| Overlay    | Description                             |
| ---------- | --------------------------------------- |
| okd        | OKD cluster with full observability     |
| microshift | MicroShift with topolvm storage         |
| k3s        | K3s cluster with Traefik ingress        |
| sno        | Single Node OpenShift with LVMS storage |

## Links

- [Technitium DNS Server](https://technitium.com/dns/)
- [Docker Hub](https://hub.docker.com/r/technitium/dns-server)
- [GitHub](https://github.com/TechnitiumSoftware/DnsServer)
- [Docker Environment Variables](https://github.com/TechnitiumSoftware/DnsServer/blob/master/DockerEnvironmentVariables.md)
