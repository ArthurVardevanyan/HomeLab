# Actions Runner Controller

```bash
SYSTEM_NAMESPACE="github-arc-systems"
helm template arc \
    --namespace "${SYSTEM_NAMESPACE}" \
    --create-namespace --include-crds \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller > github-arc-systems.yaml

INSTALLATION_NAME="homelab-arc-runner-set"
NAMESPACE="github-arc-runners"
GITHUB_CONFIG_URL="https://github.com/ArthurVardevanyan/Homelab"
GITHUB_PAT=""
helm template "${INSTALLATION_NAME}" \
    --namespace "${NAMESPACE}" \
 --create-namespace --include-crds \
 --set controllerServiceAccount.name="arc-gha-rs-controller" \
 --set controllerServiceAccount.namespace="${SYSTEM_NAMESPACE}"\
 --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
    --set githubConfigSecret.github_token="${GITHUB_PAT}" \
 oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set  > github-runner-scale-set.yaml
```

REF: <https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller>
