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

## Vault Kubernetes Integration

```bash

# Vault
kubectl exec -it vault-0 -n vault -- vault operator unseal --tls-skip-verify
# https://blog.ramon-gordillo.dev/2021/03/gitops-with-argocd-and-hashicorp-vault-on-kubernetes/
# https://cloud.redhat.com/blog/how-to-use-hashicorp-vault-and-argo-cd-for-gitops-on-openshift
# https://itnext.io/argocd-secret-management-with-argocd-vault-plugin-539f104aff05
vault auth enable kubernetes

token_reviewer_jwt=$(kubectl get secrets -n argocd -o jsonpath="{.items[?(@.metadata.annotations.kubernetes.io/service-account.name=='argocd-repo-server')].data.token}" |base64 -d)

#kubernetes_host=$(oc whoami --show-server)
kubernetes_host="https://kubernetes.default.svc:443"

# Pod With Service Account Token Mounted
kubectl cp -n vault vault-0:/var/run/secrets/kubernetes.io/serviceaccount/..data/ca.crt /tmp/ca.crt

vault write auth/arthurvardevanyan-ci/config \
   token_reviewer_jwt="${token_reviewer_jwt}" \
   kubernetes_host=${kubernetes_host} \
   kubernetes_ca_cert=@/tmp/ca.crt \
   disable_local_ca_jwt=true

vault write auth/kubernetes/role/arthurvardevanyan-ci \
    bound_service_account_names=pipeline \
    bound_service_account_namespaces=arthurvardevanyan-ci \
    policies=arthurvardevanyan-ci \
    ttl=1h

vault policy write arthurvardevanyan-ci - <<EOF
path "secret/*" {
    capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

vault write auth/kubernetes/login role=argocd jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
```

Additional Policy for Terraform

```hcl
path "auth/token/create" {
  capabilities = ["create", "read", "update", "list"]
}
```

```bash
export VAULT_TOKEN=$(vault login --tls-skip-verify -address=https://vault.arthurvardevanyan.com -method=userpass -token-only username=arthur)
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
