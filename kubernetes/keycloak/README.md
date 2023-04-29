# KeyCloak

```bash
kubectl kustomize kubernetes/keycloak/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://zhimin-wen.medium.com/running-and-testing-keycloak-on-openshift-80fd34834d1a>
