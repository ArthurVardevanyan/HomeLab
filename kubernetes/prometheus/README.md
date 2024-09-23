# Prometheus

```bash
kubectl kustomize kubernetes/prometheus/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

```bash
mc cp --recursive  ceph/prometheus-thanos-d76a2930-3b8c-4e6b-b76b-335cfe5c135c truenas/prometheus-thanos
rclone --progress copy ceph:prometheus-thanos-d76a2930-3b8c-4e6b-b76b-335cfe5c135c truenas:prometheus-thanos --ignore-existing
```

## REF

- <https://grafana.com/grafana/dashboards/9706>
- <https://grafana.com/grafana/dashboards/6417>
- <https://grafana.com/grafana/dashboards/1860>
- <https://grafana.com/grafana/dashboards/13978>
- <https://github.com/cloudworkz/kube-eagle>
- <https://ashishkr99.medium.com/persistent-prometheus-grafana-on-kubernetes-71336d3c7a22>
- <https://devopscube.com/setup-prometheus-monitoring-on-kubernetes/>
- <https://www.mytinydc.com/en/blog/prometheus-influxdb/>
- <https://www.robustperception.io/temperature-and-hardware-monitoring-metrics-from-the-node-exporter>
- <https://github.com/fritchie/nvme_exporter>
- <https://medium.com/quiq-blog/prometheus-relabeling-tricks-6ae62c56cbda>
- <https://faun.pub/how-to-drop-and-delete-metrics-in-prometheus-7f5e6911fb33>
- <https://www.shellhacks.com/prometheus-delete-time-series-metrics/>
- <https://github.com/prometheus/prometheus/issues/6046>
- <https://hackernoon.com/kubernetes-monitoring-with-prometheus-and-thanos-z91w3uc2>
