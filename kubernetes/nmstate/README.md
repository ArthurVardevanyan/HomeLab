# NMSTATE

```bash
wget -O - https://github.com/nmstate/kubernetes-nmstate/releases/download/v0.85.1/nmstate.io_nmstates.yaml                                               > kubernetes/nmstate/components/upstream/crd.yaml
wget -O - https://raw.githubusercontent.com/nmstate/kubernetes-nmstate/refs/tags/v0.85.1/deploy/crds/nmstate.io_nodenetworkconfigurationenactments.yaml  >> kubernetes/nmstate/components/upstream/crd.yaml
wget -O - https://raw.githubusercontent.com/nmstate/kubernetes-nmstate/refs/tags/v0.85.1/deploy/crds/nmstate.io_nodenetworkconfigurationpolicies.yaml    >> kubernetes/nmstate/components/upstream/crd.yaml
wget -O - https://raw.githubusercontent.com/nmstate/kubernetes-nmstate/refs/tags/v0.85.1/deploy/crds/nmstate.io_nodenetworkstates.yaml                   >> kubernetes/nmstate/components/upstream/crd.yaml

wget -O kubernetes/nmstate/components/upstream/service_account.yaml  https://github.com/nmstate/kubernetes-nmstate/releases/download/v0.85.1/service_account.yaml
wget -O kubernetes/nmstate/components/upstream/role.yaml             https://github.com/nmstate/kubernetes-nmstate/releases/download/v0.85.1/role.yaml
wget -O kubernetes/nmstate/components/upstream/role_binding.yaml     https://github.com/nmstate/kubernetes-nmstate/releases/download/v0.85.1/role_binding.yaml
wget -O kubernetes/nmstate/components/upstream/operator.yaml         https://github.com/nmstate/kubernetes-nmstate/releases/download/v0.85.1/operator.yaml

prettier kubernetes/nmstate/components/upstream --write
```
