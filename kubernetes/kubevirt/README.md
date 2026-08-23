# KubeVirt

```bash
kubectl kustomize kubernetes/kubevirt/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Table of Contents

- [KubeVirt](#kubevirt)
  - [Table of Contents](#table-of-contents)
  - [CPU Models](#cpu-models)
    - [Available Models](#available-models)
    - [Mixed CPU Environments](#mixed-cpu-environments)
    - [Recommendation](#recommendation)
  - [VM Example](#vm-example)

## CPU Models

KubeVirt supports several CPU models that expose different instruction sets and
features to the guest VM. The choice of CPU model determines what instructions
the guest can use and whether live migration is possible between hosts with
different CPU architectures.

### Available Models

| Model              | Architecture | Key Features                                                        | AVX-512         | Live Migration                  |
| ------------------ | ------------ | ------------------------------------------------------------------- | --------------- | ------------------------------- |
| `host-passthrough` | Host-native  | Exposes the exact host CPU                                          | Depends on host | Only between identical CPUs     |
| `EPYC-IBPB`        | AMD Zen 2+   | Baseline AMD Zen 2 feature set with Indirect Branch Predict Barrier | No              | Between Zen 2/3/4 AMD CPUs      |
| `EPYC-Rome`        | AMD Zen 2    | AMD Rome server CPU model                                           | No              | Between Zen 2+ AMD CPUs         |
| `host-model`       | Host-native  | Closest host CPU model with fallback                                | Depends on host | Between CPUs with same features |

### Mixed CPU Environments

When the cluster contains hosts with different CPU generations (e.g. mixing a
Ryzen 5 3600 with Zen 2, a Ryzen 7 5700G with Zen 3, and a Ryzen 7 8700G
with Zen 4), `host-passthrough` **will not work** for live migration because
the instruction sets differ between hosts.

The cluster's oldest CPU defines the instruction-set ceiling for any uniform
CPU model. In this environment:

- **Ryzen 5 3600** (Zen 2, Matisse) — oldest, limits the cluster to Zen 2
  feature set; no AVX-512 support (AVX2 ceiling)
- **Ryzen 7 5700G** (Zen 3, Cezanne) — improved IPC over Zen 2; no AVX-512
- **Ryzen 7 8700G** (Zen 4, Phoenix) — newest, adds native AVX-512, XDNA NPU

Because the Ryzen 5 3600 (Zen 2) is the oldest, `host-passthrough` would
prevent live migration to that node from newer CPUs. The safe choice is
**`EPYC-IBPB`**, which maps to the Zen 2 feature set and provides a common
instruction-set baseline across all AMD Zen 2/3/4 CPUs, enabling live
migration between any hosts in the cluster.

### Recommendation

- **Mixed CPU types**: use `EPYC-IBPB` (or `EPYC-Rome`) to ensure live
  migration compatibility across different AMD CPU generations.
- **Identical CPUs only**: `host-passthrough` or `host-model` for maximum
  performance with native CPU features.

## VM Example

The VM template at [vms/base/fedora.yaml](../../vms/base/fedora.yaml) uses
`EPYC-IBPB` as its CPU model for this reason — the cluster has nodes with
different Ryzen generations, so `host-passthrough` would break live migration.
