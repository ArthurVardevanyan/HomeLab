# InfluxDB

```bash
kubectl kustomize kubernetes/influxdb/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://www.mytinydc.com/en/blog/prometheus-influxdb/>
- <https://chowdera.com/2021/01/20210119045930742m.html>
- <https://github.com/VictorRobellini/pfSense-Dashboard>
- <https://www.paolotagliaferri.com/home-assistant-data-persistence-and-visualization-with-grafana-and-influxdb/>
- <https://github.com/dseifert/homeassistant2influxdb>
- <https://docs.influxdata.com/influxdb/v1.7/guides/downsampling_and_retention/>
- <https://community.grafana.com/t/cumulative-sum-influxdb-data/57642>
