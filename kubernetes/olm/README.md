# OLM

```bash
helm template my-olm oci://ghcr.io/cloudtooling/helm-charts/olm  --include-crds --version 0.35.0  > /tmp/olm.yaml

kubectl kustomize kubernetes/olm/overlays/microshift | | kubectl apply -f -
```
