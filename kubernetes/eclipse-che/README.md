# Eclipse Che

```bash
kubectl kustomize kubernetes/eclipse-che/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```
