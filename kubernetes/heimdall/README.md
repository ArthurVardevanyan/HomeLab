# Heimdall

```bash
kubectl kustomize kubernetes/heimdall/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/linuxserver/docker-heimdall/issues/115>
- <https://github.com/linuxserver/Heimdall/issues/926>
- <https://www.debontonline.com/2020/12/kubernetes-part-12-deploy-heimdall-yaml.html>
