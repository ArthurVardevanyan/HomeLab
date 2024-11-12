# Uptime Kuma

```bash
kubectl kustomize kubernetes/uptime-kuma/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## HA Setup

```bash
helm template vault hashicorp/vault \
  --set='server.ha.enabled=true' \
  --set='server.ha.raft.enabled=true' \
  --set='csi.agent.enabled=false' \
  --namespace vault-ha > vault-ha.yaml
```

```bash
kubectl -n vault exec -ti vault-0 -- vault operator init
kubectl -n vault  exec -ti vault-0 -- vault operator unseal

kubectl -n vault  exec -ti vault-1 -- vault operator raft  join http://vault-0.vault-internal:8200
kubectl -n vault  exec -ti vault-1 -- vault operator unseal

kubectl -n vault  exec -ti vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl -n vault  exec -ti vault-2 -- vault operator unseal
```

## REF

- <https://holdmybeersecurity.com/2021/03/04/gitlab-ci-cd-pipeline-with-vault-secrets/>
- <https://docs.gitlab.com/ee/ci/examples/authenticating-with-hashicorp-vault/>
- <https://holdmybeersecurity.com/2021/03/04/gitlab-ci-cd-pipeline-with-vault-secrets/>
- <https://learn.hashicorp.com/tutorials/vault/kubernetes-raft-deployment-guide?in=vault/kubernetes#kubernetes-namespaces>
- <https://cloud.redhat.com/blog/how-to-use-hashicorp-vault-and-argo-cd-for-gitops-on-openshift>
- <https://itnext.io/argocd-secret-management-with-argocd-vault-plugin-539f104aff05>
- <https://blog.ramon-gordillo.dev/2021/03/gitops-with-argocd-and-hashicorp-vault-on-kubernetes/>
- <https://itnext.io/argocd-secret-management-with-argocd-vault-plugin-539f104aff05>
- <https://www.vaultproject.io/docs/platform/k8s/helm/examples/ha-with-raft>
- <https://learn.hashicorp.com/tutorials/vault/agent-kubernetes>
