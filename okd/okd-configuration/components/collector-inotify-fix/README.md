# Collector Inotify Fix

Increases file descriptor limits and inotify settings on GPU nodes to support the Vector log collector.

## Table of Contents

- [Collector Inotify Fix](#collector-inotify-fix)
  - [Table of Contents](#table-of-contents)
  - [Purpose](#purpose)
  - [Resources](#resources)
  - [Values](#values)
  - [Apply](#apply)
  - [Verify](#verify)
  - [Notes](#notes)

## Purpose

The Vector collector watches thousands of log files in `/var/log/pods/`. Without these changes, it hits file descriptor limits and fails with "Too many open files" errors.

## Resources

| File                             | Type          | What it sets                                                               | When applied               |
| -------------------------------- | ------------- | -------------------------------------------------------------------------- | -------------------------- |
| `tuned.yaml`                     | TuneD CR      | `fs.inotify.max_user_watches=524288`,`fs.inotify.max_user_instances=16384` | Runtime (via TuneD daemon) |
| `96-gpu-crio-limit-files.yaml`   | MachineConfig | `nofile=1048577:1048577` (CRI-O ulimit)                                    | Boot                       |
| `97-gpu-sysctl-limit-files.yaml` | MachineConfig | `fs.nr_open=1048577`                                                       | Boot                       |

## Values

- `fs.inotify.max_user_watches = 524288` (default: 65536)
- `fs.inotify.max_user_instances = 16384` (default: 8192)
- `fs.nr_open = 1048577` (default: 1024)
- CRI-O `nofile` ulimit = `1048577:1048577` (default: 1024)

## Apply

Sync via ArgoCD (managed by `okd-configuration` application), or apply manually:

```bash
kubectl apply -f okd/okd-configuration/components/collector-inotify-fix/tuned.yaml
kubectl apply -f okd/okd-configuration/components/collector-inotify-fix/96-gpu-crio-limit-files.yaml
kubectl apply -f okd/okd-configuration/components/collector-inotify-fix/97-gpu-sysctl-limit-files.yaml
```

## Verify

After applying and rebooting gpu-1:

```bash
# Check TuneD profile
kubectl get profile gpu-1 -n openshift-cluster-node-tuning-operator -o jsonpath='{.spec.config.tunedProfile}'

# Check sysctl values
ssh core@10.101.10.107 'sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances fs.nr_open'

# Check CRI-O ulimit
kubectl exec -n openshift-logging collector-<pod> -- ulimit -n
# Expected: 1048577

# Check Vector collector logs
kubectl logs -n openshift-logging collector-<pod> --tail=100 | grep "Too many open files"
# Expected: no errors
```

## Notes

- MachineConfigs require a reboot to take effect
- MachineConfigs for CRI-O ulimit and `fs.nr_open` are **unsupported** and require a Red Hat support exception
- Pause the GPU MCP before applying to control reboot timing:
