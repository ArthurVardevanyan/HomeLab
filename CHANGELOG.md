<!-- markdownlint-disable MD024 MD007 -->

# Changelog

## Overview

This document analyzes the git history of the HomeLab project, grouping changes into distinct historic eras based on technology shifts and major milestones.

## Summary

| Era                 | Timeframe  | Orchestration      | Management               | CI/CD & Source Control | Storage           | Observability              | Networking                    | Security & Identity |
| :------------------ | :--------- | :----------------- | :----------------------- | :--------------------- | :---------------- | :------------------------- | :---------------------------- | :------------------ |
| **Windows Server**  | Early 2016 | -                  | RDP, GUI                 | -                      | NTFS              | -                          | -                             | Active Directory    |
| **Vmware/Windows**  | Late 2016  | VMware Workstation | GUI                      | -                      | Local vmdk        | -                          | Bridged/NAT                   | -                   |
| **Vmware/Linux**    | 2017-2018  | Systemd/Manual     | Shell, Webmin            | -                      | FreeNAS           | -                          | pfSense                       | -                   |
| **Storage**         | 2019       | VMs                | Shell                    | -                      | FreeNAS           | -                          | pfSense (VM)                  | -                   |
| **VFIO**            | 2020       | KVM / VMware       | Shell                    | -                      | TrueNAS Core      | -                          |                               | -                   |
| **Docker**          | Early 2021 | Docker Compose     | Shell Scripts, Portainer | GitLab                 | Local Bind Mounts | -                          | MacVLAN (L2), ISP Router      | -                   |
| **K3s**             | Late 2021  | K3s                | Ansible (IaC)            | GitLab CI              | Longhorn (Block)  | Prometheus, Grafana        | Traefik, Flannel              | Vault, Bitwarden    |
| **OKD**             | Early 2022 | OKD (OpenShift)    | ArgoCD (GitOps)          | Tekton, Gitea, Quay    | MinIO, ODF (Rook) | -                          | SDN, Routes, MetalLB, pfSense | -                   |
| **Security**        | Late 2022  | OKD                | ArgoCD                   | Tekton, Gitea          | Ceph / ODF        | Stackrox, Smoke Tests      | SDN, Routes, pfSense          | Clair               |
| **Identity**        | Early 2023 | OKD                | ArgoCD                   | Tekton, Gitea          | Ceph / ODF        | Network Observability      | SDN, Routes, pfSense          | Zitadel (OIDC)      |
| **DevExp**          | Late 2023  | OKD                | ArgoCD                   | Tekton, Gitea          | Ceph / ODF        | -                          | SDN, Routes, pfSense          | Kyverno             |
| **Network/Storage** | Early 2024 | OKD                | ArgoCD                   | Tekton, Gitea          | Ceph / ODF        | -                          | Kube-VIP, UniFi               | External Secrets    |
| **Virt**            | Late 2024  | OKD / MicroShift   | AWX, Netbox              | Tekton, Gitea          | Ceph, LVM         | Loki, Logging              | Cloudflare DDNS               | -                   |
| **Bare Metal**      | Early 2025 | OKD IPI / SNO      | Agent Installer          | Tekton, Gitea          | Ceph, LVM         | Power Monitoring           | OVN-K8s                       | KFCA                |
| **Accel**           | Late 2025  | OKD IPI            | Agent Installer          | Tekton, Gitea          | Ceph, LVM         | VictoriaMetrics, Dragonfly | Gateway API, Service Mesh     | NetworkPolicy       |

- [Changelog](#changelog)
  - [Overview](#overview)
  - [Summary](#summary)
  - [1. Windows Server (Early 2016)](#1-windows-server-early-2016)
  - [2. VMware Workstation (Late 2016)](#2-vmware-workstation-late-2016)
  - [3. The Rise of Self-Hosting (2017 - 2018)](#3-the-rise-of-self-hosting-2017---2018)
  - [4. Advanced Storage \& Networking (2019)](#4-advanced-storage--networking-2019)
  - [5. Hardware \& Passthrough (2020)](#5-hardware--passthrough-2020)
  - [6. The Docker Era (Early 2021 - August 2021)](#6-the-docker-era-early-2021---august-2021)
    - [Key Characteristics](#key-characteristics)
    - [Major Milestones](#major-milestones)
  - [7. Kubernetes Migration (August 2021 - December 2021)](#7-kubernetes-migration-august-2021---december-2021)
    - [Key Characteristics](#key-characteristics-1)
    - [Major Milestones](#major-milestones-1)
  - [8. The OKD Migration (Early 2022)](#8-the-okd-migration-early-2022)
    - [Key Characteristics](#key-characteristics-2)
    - [Major Milestones](#major-milestones-2)
  - [9. Security \& Stability (Late 2022)](#9-security--stability-late-2022)
    - [Key Characteristics](#key-characteristics-3)
    - [Major Milestones](#major-milestones-3)
  - [10. Identity \& Observability (Early 2023)](#10-identity--observability-early-2023)
    - [Key Characteristics](#key-characteristics-4)
    - [Major Milestones](#major-milestones-4)
  - [11. Developer Experience \& Serverless (Late 2023)](#11-developer-experience--serverless-late-2023)
    - [Key Characteristics](#key-characteristics-5)
    - [Major Milestones](#major-milestones-5)
  - [12. Hybrid Networking \& Storage (Early 2024)](#12-hybrid-networking--storage-early-2024)
    - [Key Characteristics](#key-characteristics-6)
    - [Major Milestones](#major-milestones-6)
  - [13. Virtualization \& Edge (Late 2024)](#13-virtualization--edge-late-2024)
    - [Key Characteristics](#key-characteristics-7)
    - [Major Milestones](#major-milestones-7)
  - [14. The Bare Metal Rebuild (Early 2025)](#14-the-bare-metal-rebuild-early-2025)
    - [Key Characteristics](#key-characteristics-8)
    - [Major Milestones](#major-milestones-8)
  - [15. Hardware Acceleration \& Observability 2.0 (Late 2025)](#15-hardware-acceleration--observability-20-late-2025)
    - [Key Characteristics](#key-characteristics-9)
    - [Major Milestones](#major-milestones-9)

## 1. Windows Server (Early 2016)

- **Focus:** Enterprise Windows environment simulation.
- **OS:** Windows Server 2012 R2.
- **Key Tech:** Active Directory Domain Services, IIS, DNS, DHCP.
- **Hardware:** Initial dedicated server hardware acquisition.

## 2. VMware Workstation (Late 2016)

- **Focus:** Desktop Virtualization and Linux exploration.
- **Platform:** VMware Workstation Pro 12 running on Windows.
- **Experiments:** Early Linux adoption (Ubuntu, Kali, Mint) running as VMs. **OpenVPN** (August 2016) running in a custom VM.
- **Key Tech:** XRDP for remote access, Virtual Network Editor.

## 3. The Rise of Self-Hosting (2017 - 2018)

- **Infrastructure:** Introduction of **FreeNAS** for storage and **pfSense** for routing (August 2017). **OpenVPN** on pfSense (February 2017).
- **Workloads:** **Nextcloud** (v11) inception, Bind9 DNS.
- **OS:** Shift towards Ubuntu Server 16.04 as the primary host.
- **Desktop:** Deep dive into Ubuntu Desktop and ZFS on Linux.
- **Apps:** Nextcloud, Spotify on Linux, and Minecraft Servers.

## 4. Advanced Storage & Networking (2019)

- **Storage:** Heavy focus on **FreeNAS** tuning (ZFS RAID levels, SSD Caching, Scrubs).
- **Networking:** Virtualizing **pfSense**, VLAN segmentation
- **Key Tech:** iSCSI for VM storage, NFS for file sharing.
- **Experiments:** Active Directory on Linux (Samba 4).

## 5. Hardware & Passthrough (2020)

- **Hardware:** Raspberry Pi 4 for OctoPrint.
- **OS:** Distro hopping (Pop!\_OS, Manjaro, Fedora).
- **Migrations:** P2V (Physical to Virtual) migrations of legacy Windows machines.
- **Networking:** **WireGuard** (April 2020) exploration.

## 6. The Docker Era (Early 2021 - August 2021)

The project began as a standard Docker-based HomeLab environment, utilizing Docker Compose for orchestration and shell scripts for management. This era marked the pivot from heavy VMs to lightweight containers and the inception of the **Git** repository, bringing version control to the infrastructure.

### Key Characteristics

- **The Pivot:** Realization of the overhead of pure VMs vs Containers.
- **Preparation:** Researching Docker, Podman, and container networking.
- **OS:** Ubuntu 21.04 and Pop!\_OS as container hosts.
- **Transition:** Migrating Nextcloud and Plex from heavy VMs to lightweight containers.
- **Orchestration:** Docker Compose.
- **Networking:** Heavy use of `macvlan` for assigning physical IPs to containers. **Default ISP Router** used for gateway.
- **Management:** Manual shell scripts (`main.bash`), **Cockpit** (June 2021), and Portainer (added July 2021).
- **Storage:** Local bind mounts mapped to the host filesystem.

### Major Milestones

- **Early 2021**: Researching Docker, Podman, and container networking.
- **June 15, 2021**: Initial Commit establishing the Docker environment.
- **June 18, 2021**: Implementation of `macvlan` network routes, moving away from simple bridge networking.
- **June 25, 2021**: **Cockpit** configuration for server management.
- **July 31, 2021**: Introduction of **Portainer** for UI-based container management.
- **Workloads:** Nextcloud, MariaDB, HomeAssistant, Spotify Analytics, Pi-Hole, **GitLab** (Code Hosting).

## 7. Kubernetes Migration (August 2021 - December 2021)

A major architectural shift towards container orchestration using Kubernetes, specifically K3s. This era marked the beginning of "Infrastructure as Code" with Ansible.

### Key Characteristics

- **Orchestration:** K3s (initially single node).
- **Configuration Management:** **Ansible** introduced (Sept 2021) to manage underlying hardware (Desktop, Laptop, Server).
- **CI/CD:** **GitLab CI** runners deployed on Kubernetes for pipeline execution.
- **Storage:** Transition from local binds to **Longhorn** for distributed block storage.
- **Ingress:** **Traefik** replaced direct port mapping.

### Major Milestones

- **August 22, 2021**: First Kubernetes-related commits appear.
- **September 8, 2021**: "Kubernetes Move" - The official migration point from Docker Compose.
- **November 28, 2021**: Full conversion to Longhorn PV/PVCs, enabling stateful workload mobility.
- **December 10, 2021**: **Bitwarden** (Vaultwarden) inception for password management.
- **Late 2021**: Introduction of **Kubernetes Dashboard**, **Metrics Server**, and **Kube Eagle** for cluster visibility.
- **Workloads**: Prometheus/Grafana stack, Heimdall Dashboard, Bitwarden, Uptime Kuma, Cert-Manager, Hashicorp Vault.

## 8. The OKD Migration (Early 2022)

Adoption of OKD (OpenShift Kubernetes Distribution) marked a move towards enterprise-grade Kubernetes and GitOps practices.

### Key Characteristics

- **Platform:** OKD 4.9 (OpenShift) replacing K3s.
- **Networking:** Transition to **pfSense** (Feb 2022) for advanced routing and VLAN management.
- **GitOps:** **ArgoCD** became the single source of truth for all application deployments.
- **CI/CD:** **Tekton** pipelines for building images and **Quay** (May 2022) for container registry.
- **Source Control:** Migration from GitLab to **Gitea** (May 2022).
- **Storage:** **MinIO** (May 2022) introduced for S3-compatible object storage.

### Major Milestones

- **January 16, 2022**: Upgrade of K3s to **High Availability (HA)** mode.
- **February 6, 2022**: **pfSense** physical inception, replacing the default ISP router.
- **March 27, 2022**: Automated Sandbox OKD Installation.
- **March 28, 2022**: Inception of **ArgoCD**, establishing the GitOps workflow.
- **May 21, 2022**: **Gitea** inception, replacing GitLab.
- **May 21, 2022**: **Tekton** pipelines implemented.
- **May 22, 2022**: **MinIO**, **Quay**, and **Postgres** inception.

## 9. Security & Stability (Late 2022)

Focus on hardening the cluster security posture and ensuring reliability through automated testing.

### Key Characteristics

- **Security:** **Stackrox (ACS)** and **Clair** for vulnerability scanning.
- **Storage:** Introduction of **TrueNAS** (Nov 2022) for dedicated backup storage.
- **Validation:** Automated smoke tests for cluster health verification.

### Major Milestones

- **October 20, 2022**: **Stackrox** inception for continuous security monitoring.
- **November 3, 2022**: **TrueNAS** inception serving as an S3 backup target.
- **November 25, 2022**: **Smoke Tests** implementation for cluster validation.

## 10. Identity & Observability (Early 2023)

Centralizing identity management and enhancing network visibility.

### Key Characteristics

- **Identity:** Transition from Keycloak to **Zitadel** (May 2023) for centralized OIDC/OAuth2.
- **Observability:** **Network Observability** (Jan 2023) for traffic analysis.
- **Reliability:** **Keep Alive** service for connection persistence.

### Major Milestones

- **January 11, 2023**: **Network Observability** inception.
- **April 27, 2023**: **Keep Alive** service for connection persistence.
- **May 1, 2023**: **Zitadel** inception, replacing Keycloak.

## 11. Developer Experience & Serverless (Late 2023)

Enhancing the platform for developers with cloud-native environments and serverless capabilities.

### Key Characteristics

- **Serverless:** **Knative** (Nov 2023) for serverless workloads.
- **Policy:** **Kyverno** (Oct 2023) for cluster policy enforcement.
- **DevTools:** **Eclipse Che** (Oct 2023) for cloud-native development environments.

### Major Milestones

- **October 29, 2023**: **Eclipse Che** inception.
- **October 30, 2023**: **Kyverno** and **Image Puller** inception.
- **November 21, 2023**: **Knative** Serverless inception.

## 12. Hybrid Networking & Storage (Early 2024)

Expansion into advanced networking hardware and enterprise-grade storage solutions.

### Key Characteristics

- **Storage:** Strategic shift from Longhorn to **Ceph/ODF** (April 2024).
- **Networking:** **Kube-VIP** (Jan 2024) and **Cloudflare DDNS** (Dec 2024). Transition to **UniFi** gear (Feb 2024).
- **Disaster Recovery:** **Velero** (May 2024) for cluster backup.

### Major Milestones

- **January 31, 2024**: **Kube-VIP** inception.
- **February 9, 2024**: **UniFi Network Application** inception, marking the shift from pfSense to UniFi hardware.
- **February 2024**: **External Secrets Operator** and **MongoDB Operator**.
- **March 7, 2024**: **GitHub Runners** for self-hosted CI/CD capacity.
- **April 5, 2024**: Strategic shift to **Ceph**.
- **May 27, 2024**: **Velero** inception for disaster recovery.

## 13. Virtualization & Edge (Late 2024)

The project expanded into Edge computing and Virtualization, effectively becoming a unified platform.

### Key Characteristics

- **Virtualization:** **KubeVirt** (June 2024) to run VMs alongside containers.
- **Edge:** **MicroShift** (Sept 2024) for resource-constrained environments.
- **Automation:** **AWX** (Oct 2024) for Ansible management and **Netbox** (Dec 2024) for IPAM.
- **Logging:** **OpenShift Logging** (Dec 2024) stack.
- **Networking:** **UniFi WireGuard** (Dec 2024) implementation on UDM Pro.

### Major Milestones

- **June 28, 2024**: **KubeVirt** inception.
- **July 4, 2024**: **NMState** for declarative network configuration.
- **July 13, 2024**: **Nested Virtualization** enabled in KubeVirt.
- **September 8, 2024**: **MicroShift** inception.
- **September 11, 2024**: **External DNS** and **OLM** (Operator Lifecycle Manager) enhancements.
- **October 10, 2024**: **AWX** inception.
- **Late 2024**: **Blackbox Exporter**, **Observability Operator**, and **NTP** standardization.
- **December 2024**: **UniFi WireGuard** implementation.
- **December 13, 2024**: **Netbox** inception.

## 14. The Bare Metal Rebuild (Early 2025)

A major rebuild focusing on bare-metal performance, starting with a transitional SNO deployment.

### Key Characteristics

- **Platform:** **Single Node OpenShift (SNO)** (Interim) and **Agent-based Installer** (Final).
- **Hardware:** **Power Monitoring** (Apr 2025).
- **Audit:** **KFCA** (Kubernetes Full Cluster Audit).

### Major Milestones

- **Early 2025**: **Major Rebuild** - Transition to OKD Baremetal IPI with Agent-based Installer.
- **March 7, 2025**: **Single Node OpenShift (SNO)** deployment with LVM storage serving as a critical stop-gap during the bare-metal migration.
- **March 31, 2025**: **Deployment Validation** operator.
- **April 1, 2025**: **OpenShift Power Monitoring**.
- **April 5, 2025**: **Automated Nested OKD/OpenShift** support in KubeVirt.
- **April 16, 2025**: **KFCA** (Kubernetes Full Cluster Audit).

## 15. Hardware Acceleration & Observability 2.0 (Late 2025)

Focus on GPU integration, advanced networking, and next-gen observability.

### Key Characteristics

- **Hardware:** **GPU Integration** (Nov 2025).
- **Storage:** **UNAS** (Aug 2025) added for high-capacity storage.
- **Networking:** **Service Mesh** (Nov 2025) and **Gateway API**.
- **Observability 2.0:** **VictoriaMetrics** (Nov 2025) and **Dragonfly**.
- **Apps:** **Immich** (July 2025) for photo management.

### Major Milestones

- **July 22, 2025**: **Immich** inception.
- **August 9, 2025**: **Kube Descheduler** for workload optimization.
- **August 30, 2025**: **UNAS** inception for storage workloads.
- **October 3, 2025**: **Nextcloud Architecture Rebuild** - Migration to FPM/S3 architecture.
- **November 8, 2025**: **GPU Integration** (#281) and **Node Feature Discovery**.
- **November 15, 2025**: **OpenShift Service Mesh**.
- **November 18, 2025**: Adoption of **VictoriaMetrics**.
- **Late 2025**: **BMC Shim** for bare-metal autoscaling.
