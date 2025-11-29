# Tekton

```bash
wget -o /tmp/dump.yaml https://github.com/tektoncd/operator/releases/download/v0.77.0/openshift-release.yaml
kubectl kustomize kubernetes/tekton/overlays/operator | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/tektoncd/operator/issues/831>
- <https://github.com/tektoncd/operator/issues/1422>
- <https://github.com/tektoncd/operator/issues/1421>
- <https://tekton.dev/docs/pipelines/install/#installing-tekton-pipelines-on-openshift>
- <https://github.com/tektoncd/operator/pull/380>
- <https://github.com/tektoncd/operator/issues/733>
- <https://github.com/redhat-scholars/tekton-tutorial>
- <https://github.com/tektoncd/pipeline/issues/4542>
- <https://github.com/tektoncd/operator/pull/592>
- <https://tekton.dev/>
- <https://github.com/tektoncd/operator/blob/main/cmd/openshift/operator/kodata/tekton-addon/addons/05-tkncliserve/tkn_cli_serve.yaml>
- <https://github.com/redhat-scholars/tekton-tutorial>
