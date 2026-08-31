# GPU Power Tuning Notes

## Table Of Contents

- [GPU Power Tuning Notes](#gpu-power-tuning-notes)
  - [Table Of Contents](#table-of-contents)
  - [Intel Arc Pro B70 (Battlemage / Xe2)](#intel-arc-pro-b70-battlemage--xe2)
    - [Hardware](#hardware)
    - [Power Tuning](#power-tuning)
      - [Configuration](#configuration)
      - [Why power limit?](#why-power-limit)
      - [Power-to-performance relationship](#power-to-performance-relationship)
      - [Measured Performance (150W cap)](#measured-performance-150w-cap)
      - [How power limits are applied](#how-power-limits-are-applied)
      - [Monitoring](#monitoring)
      - [Future improvements](#future-improvements)
    - [References](#references)

## Intel Arc Pro B70 (Battlemage / Xe2)

### Hardware

| Attribute     | Value                                                     |
| ------------- | --------------------------------------------------------- |
| Model         | Intel Arc Pro B70 (Battlemage / Xe2)                      |
| Quantity      | 2x on gpu-1                                               |
| Memory        | ~32 GB GDDR6 per card                                     |
| PCIe Slot 1   | Gen4 x4, `0000:06:00.0` (top slot, direct CPU lanes)      |
| PCIe Slot 2   | Gen3 x4, `0000:2d:00.0` (bottom slot, B550 chipset lanes) |
| KMD           | `xe`                                                      |
| TDP (rated)   | 160W per card                                             |
| Boost power   | ~230W per card (observed under heaviest LLM load)         |
| Thermal limit | ~100°C (thermal throttle)                                 |

### Power Tuning

#### Configuration

The power limit is set by the **`gpu-power-manager`** DaemonSet via the `POWER_LIMIT_WATTS` environment variable.

**Current setting: 155W** — see [`gpu-power-manager.yaml`](../intel-device-plugins/base/gpu-power-manager.yaml).

To change:

```bash
oc set env daemonset/gpu-power-manager -n intel-device-plugins-operator POWER_LIMIT_WATTS=<new_value>
```

#### Why power limit?

Both GPUs draw ~180W average under LLM inference load (360W total), with peaks up to ~230W under heaviest load. Power limiting reduces both heat output and power consumption.

Measured decode throughput (SYCL backend, Qwen3.6-35B-A3B):

- **Average:** 30-45 t/s (most chat requests, 200 tokens)
- **Peak:** 50-55+ t/s (light requests)
- **Context processing:** 10-55 t/s (varies by prompt size)

#### Power-to-performance relationship

| Power Limit       | Est. Perf (t/s) | Perf Loss vs Peak | Power Savings |
| ----------------- | --------------- | ----------------- | ------------- |
| 230W (stock peak) | 30-55 t/s       | 0% (baseline)     | —             |
| 180W              | ~28-50 t/s      | ~5%               | ~50W/GPU      |
| **155W**          | **~25-45 t/s**  | **~10%**          | **~75W/GPU**  |
| 140W              | ~20-40 t/s      | ~15-20%           | ~90W/GPU      |

**155W is the chosen setting** — balances cost savings with acceptable performance:

- ~10% performance loss from peak — imperceptible for chat workloads (3-10s → 3.5-11s)
- 75W power savings per GPU (150W total) — ~$57/year savings at $0.15/kWh
- Average power draw drops from ~180W to ~155W per GPU
- Occasional 100K+ token prompts may be slightly slower but still functional

#### Measured Performance (150W cap)

Real-world data from 20-minute sample at 150W power limit (Qwen3.6-35B-A3B, SYCL):

| Metric                 | GPU0      | GPU1      |
| ---------------------- | --------- | --------- |
| Avg Decode Throughput  | 24-44 t/s | 44-51 t/s |
| Peak Decode Throughput | 44-90 t/s | 46-68 t/s |
| Context Processing     | 5-90 t/s  | 44-51 t/s |

- GPU1 consistently outperforms GPU0 (likely better cooling/PCIe lanes)
- Average decode (~30-40 t/s) matches our estimates
- Peak values reach 50-90+ t/s for light requests
- Context processing varies by prompt size (5-90 t/s)

#### How power limits are applied

Power limits are set via a **privileged DaemonSet** (`gpu-power-manager`) in the `intel-device-plugins-operator` namespace. This DaemonSet runs on GPU nodes and maintains power limits continuously via a background loop.

Configuration is in `kubernetes/intel-device-plugins/base/gpu-power-manager.yaml`:

- DaemonSet `gpu-power-manager` writes `${POWER_LIMIT_WATTS}000000` (power limit in micro-watts) to each GPU's sysfs `power1_cap` file on startup:
  - GPU 0: `/sys/class/drm/card0/device/hwmon/hwmon2/power1_cap`
  - GPU 1: `/sys/class/drm/card1/device/hwmon/hwmon3/power1_cap`
- Runs a background loop (`sleep 300`) to maintain limits (handles driver reloads, pod restarts)
- Runs as privileged to access the host's sysfs directly (sysfs must be writable, not mounted via hostPath)
- No GPU resource requests needed — sysfs power limits work independently of device allocation

#### Monitoring

Power, temperature, and utilization metrics are available via:

- **xpumd** (Intel XPU Manager Daemon): scrapes `hw_power_watts{hw_sensor_location="gpu"}` every 30s
- **Prometheus**: scrape target `xpumd.intel-device-plugins-operator.svc.cluster.local:8080`
- **Grafana dashboard**: `kubernetes/grafana/base/dashboards/intel-gpu.json`
- **xpu-smi** (on-demand): `xpu-smi stats -d 0 -m 5` (power metrics group)

Verify the limit is active:

```bash
# Check sysfs power limits (current cap in micro-watts)
cat /sys/class/drm/card0/device/hwmon/hwmon2/power1_cap
cat /sys/class/drm/card1/device/hwmon/hwmon3/power1_cap

# Check current power draw (energy counter, sample twice and diff for watts)
cat /sys/class/drm/card0/device/hwmon/hwmon2/energy1_input
cat /sys/class/drm/card1/device/hwmon/hwmon3/energy1_input

# Check gpu-power-manager env var (source of truth)
kubectl get ds gpu-power-manager -n intel-device-plugins-operator -o jsonpath='{.spec.template.spec.containers[0].env[0].value}{"\n"}'

# Check gpu-power-manager logs
kubectl logs -n intel-device-plugins-operator ds/gpu-power-manager

# Check gpu-power-manager pod (should be running the loop)
kubectl get pods -n intel-device-plugins-operator -l app=gpu-power-manager -o wide
```

#### Future improvements

- **Level Zero env var:** If `ZE_POWER_LIMIT` is supported by the runtime, it would eliminate the need for the DaemonSet and sysfs mounts. Track this in the intel-compute-runtime release notes.
- **Per-GPU limits:** GPU1 (worse airflow) could benefit from a lower limit while GPU0 runs at the configured value. This would be a future optimization if GPU1 remains hotter.

### References

- [Intel Arc Pro B70](https://www.intel.com)
- [Intel Xe Compute Runtime](https://github.com/intel/compute-runtime)
- [xpu-smi documentation](https://dgpu-docs.intel.com/)
- [Level Zero Power Extension](https://github.com/oneapi-src/level-zero)
- [llama-swap README](../llm/components/llama-swap/README.md)
