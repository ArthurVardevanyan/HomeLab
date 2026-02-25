# Network Observability

OpenShift Network Observability Operator deployment using the `netobserv-operator` from Red Hat's operator catalog. Collects network flow data via eBPF agents, processes flows through a pipeline, and exposes traffic insights in the OCP console.

## Apply

```bash
kubectl kustomize kubernetes/network-observability/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ openshift-netobserv-privileged (privileged PSA)                     │
│   netobserv-ebpf-agent  [DaemonSet]  — captures flows on each node  │
└────────────────────────────┬────────────────────────────────────────┘
                             │ flows (gRPC)
┌────────────────────────────▼────────────────────────────────────────┐
│ openshift-netobserv (privileged PSA)                                │
│   flowlogs-pipeline     [DaemonSet]  — enriches & exports metrics   │
│   netobserv-plugin      [Deployment] — console plugin UI            │
└──────────────┬──────────────────────────┬───────────────────────────┘
               │ metrics (Prometheus)     │ logs/flows (Loki, disabled in OKD)
┌──────────────▼──────────────────────┐  │
│ openshift-netobserv-operator        │  │
│   (restricted PSA)                  │  │
│   netobserv-controller-manager      │  │
│     [Deployment] — operator         │  │
│   netobserv-plugin-static           │  │
│     [Deployment] — static assets    │  │
└─────────────────────────────────────┘  │
                              ┌──────────▼──────────────────────────────┐
                              │ openshift-netobserv-loki (restricted PSA)│
                              │   LokiStack  [StatefulSets]              │
                              │     — log storage backed by Ceph S3      │
                              └──────────────────────────────────────────┘
```

Loki is **disabled** in the OKD overlay. Flow data is surfaced entirely through Prometheus metrics and the console plugin. The Loki URLs remain configured in `base/flow-collector.yaml` for reference but are inactive.

## Namespaces

| Namespace                        | PSA Level  | Purpose                                     |
| -------------------------------- | ---------- | ------------------------------------------- |
| `openshift-netobserv-operator`   | restricted | Operator controller + static plugin assets  |
| `openshift-netobserv`            | privileged | Flow pipeline + console plugin              |
| `openshift-netobserv-privileged` | privileged | eBPF agent DaemonSet (requires host access) |
| `openshift-netobserv-loki`       | restricted | Loki stack (deployed but disabled in OKD)   |

## Operator

- **Source**: `redhat-operators` (stable channel)
- **Starting CSV**: `network-observability-operator.v1.11.0`
- **Install Plan**: Manual approval (managed by `installplan-approver`)

## eBPF Agent Configuration

Sampling rate: **1 in 75** flows (tunable via `spec.agent.ebpf.sampling`).

Enabled features:

| Feature             | Description                                          |
| ------------------- | ---------------------------------------------------- |
| `PacketDrop`        | Tracks dropped packets with drop reason              |
| `DNSTracking`       | Captures DNS queries/responses for NXDomain analysis |
| `FlowRTT`           | Measures TCP round-trip time                         |
| `NetworkEvents`     | OVN network events (ACL drops, etc.)                 |
| `PacketTranslation` | NAT/SNAT translation tracking                        |
| `UDNMapping`        | User-Defined Network mapping                         |

> **Note**: `IPSec` feature is disabled. Enabling it causes `ipsec_egress_map: cannot allocate memory` fatal errors on nodes without XFRM kernel support.

## Storage — Object Bucket Claim

Flow data (when Loki is enabled) is backed by a Rook/Ceph S3 bucket provisioned via `ObjectBucketClaim`:

- **Namespace**: `openshift-netobserv-loki`
- **Storage class**: `rook-ceph-bucket`
- **Max size**: 500 GiB
- **Bucket name**: auto-generated with prefix `netobserv`

## Scaling & Resources

### HPA

`netobserv-plugin-static` (in `openshift-netobserv-operator`) is horizontally scaled:

- Min replicas: **2**, Max replicas: **3**
- Scale trigger: CPU utilization ≥ 100%

### VPAs (OKD overlay)

| Workload                       | Namespace                        | Kind       | Max CPU | Max Memory |
| ------------------------------ | -------------------------------- | ---------- | ------- | ---------- |
| `netobserv-controller-manager` | `openshift-netobserv-operator`   | Deployment | 100m    | 400Mi      |
| `netobserv-plugin-static`      | `openshift-netobserv-operator`   | Deployment | 100m    | 256Mi      |
| `netobserv-plugin`             | `openshift-netobserv`            | Deployment | 150m    | 256Mi      |
| `flowlogs-pipeline`            | `openshift-netobserv`            | DaemonSet  | 300m    | 512Mi      |
| `netobserv-ebpf-agent`         | `openshift-netobserv-privileged` | DaemonSet  | 300m    | 512Mi      |

All VPAs use `updateMode: InPlaceOrRecreate`.

### Kyverno Resource Injection

`netobserv-plugin-static` has `resources: {}` in its operator-managed Deployment. A namespaced Kyverno `Policy` in `openshift-netobserv-operator` injects resource requests/limits on admission:

- **Requests**: 5m CPU / 32Mi memory
- **Limits**: 100m CPU / 128Mi memory

This is required for the VPA to function (VPA needs an existing resource spec to modify).

## Network Policies

Deny-all default with explicit allow rules in all four namespaces. Key egress rules:

- All namespaces allow egress to `openshift-dns` (port 5353 UDP/TCP)
- All namespaces allow egress to the API server
- `openshift-netobserv-privileged` → `openshift-netobserv` (flow data)
- `openshift-netobserv` → `openshift-netobserv-loki` (Loki writes, when enabled)
- `openshift-netobserv-loki` → `rook-ceph` (S3 object storage, port 8080)

## Egress Firewall (OKD overlay)

OVN `EgressFirewall` resources restrict all four namespaces to only egress to control-plane nodes. All other outbound traffic is denied.

## Directory Structure

```
network-observability/
├── base/
│   ├── flow-collector.yaml        # FlowCollector CR (v1beta2)
│   ├── hpa.yaml                   # HPA for netobserv-plugin-static
│   ├── installplan-approver.yaml  # Auto-approves manual InstallPlans
│   ├── kyverno.yaml               # Resource injection for plugin-static
│   ├── namespace.yaml             # All four namespaces
│   ├── network-policy.yaml        # Policies for operator + netobserv ns
│   ├── network-policy-priv.yaml   # Policies for privileged ns
│   ├── object-bucket-claim.yaml   # Ceph S3 bucket for Loki
│   ├── operator-group.yaml
│   ├── subscription.yaml          # OLM subscription (v1.11.0, manual)
│   └── loki/
│       ├── kyverno.yaml           # Resource limits for all Loki components
│       ├── network-policy.yaml    # Policies for loki ns
│       ├── rbac.yaml              # Loki reader/writer ClusterRoles
│       └── secret.yaml            # Loki S3 credentials
└── overlays/
    └── okd/
        ├── egress-firewall.yaml   # OVN EgressFirewall (control-plane only)
        ├── flow-collector-patch.yaml  # Disables Loki (sets enable: false)
        ├── kustomization.yaml
        └── vpa.yaml               # VPAs for all five workloads
```

## References

- [Network Observability Operator docs](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/network_observability)
- [DNSNxDomain Runbook](https://github.com/openshift/runbooks/blob/master/alerts/network-observability-operator/DNSNxDomain.md)
- [FlowCollector API reference](https://github.com/netobserv/network-observability-operator/blob/main/docs/FlowCollector.md)
- [netobserv/documents — Loki distributed](https://github.com/netobserv/documents/blob/main/loki_distributed.md)
- [Kubernetes DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
