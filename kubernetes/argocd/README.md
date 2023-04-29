# ArgoCD

```bash
kubectl kustomize kubernetes/argocd/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://blog.ramon-gordillo.dev/2021/03/gitops-with-argocd-and-hashicorp-vault-on-kubernetes/>
- <https://cloud.redhat.com/blog/how-to-use-hashicorp-vault-and-argo-cd-for-gitops-on-openshift>
- <https://computingforgeeks.com/how-to-install-argocd-on-openshift-cluster/>
- <https://github.com/argoproj/argo-cd/issues/3474>
- <https://github.com/argoproj/argo-cd/issues/5886>
- <https://github.com/argoproj-labs/argocd-operator/issues/204>
- <https://github.com/argoproj-labs/argocd-operator/pull/455>
- <https://itnext.io/argocd-secret-management-with-argocd-vault-plugin-539f104aff05>
- <https://argocd-vault-plugin.readthedocs.io/en/stable/>
