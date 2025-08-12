# Spire

```bash
helm template -n spire-mgmt spire spire --include-crds \
 --repo https://spiffe.github.io/helm-charts-hardened/ \
 -f values.yaml

helm template -n spire-mgmt spire-crds  --include-crds \
 --repo https://spiffe.github.io/helm-charts-hardened/
```
