# OKD

- [OKD](#okd)
  - [Deploy](#deploy)
  - [OKD WIF](#okd-wif)
  - [MTU Change](#mtu-change)
  - [REF](#ref)

## Deploy

```bash
kubectl kustomize okd/okd-configuration/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
kubectl kustomize okd/openshift-monitoring/overlays/default | argocd-vault-plugin generate - | kubectl apply -f -
```

## OKD WIF

- <https://github.com/openshift/cloud-credential-operator/blob/master/docs/gcp_workload_identity.md>
- <https://github.com/openshift/cloud-credential-operator/blob/master/docs/ccoctl.md>

File Configuration Locations

```bash
ls ./terraform/gcp/HomeLab/homelab
ls ./terraform/gcp/HomeLab/homelab/wif
ls ./okd/okd-configuration/wif.yaml
```

CCOCTL Binary: <https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/stable/ccoctl-linux.tar.gz>

```bash
PROJECT_ID="$(vault kv get -field=project_id secret/gcp/org/av/projects)"

./ccoctl gcp create-workload-identity-pool --name=okd-homelab-wif --project=homelab-${PROJECT_ID} --dry-run
./ccoctl gcp create-workload-identity-provider --name=okd-homelab-wif --region=us --project=homelab-${PROJECT_ID} \
  --public-key-file=serviceaccount-signer.public --workload-identity-pool=okd-homelab-wif --dry-run
```

## MTU Change

- <https://docs.openshift.com/container-platform/4.16/networking/changing-cluster-network-mtu.html#nw-cluster-mtu-change_changing-cluster-network-mtu>

```bash
oc patch Network.operator.openshift.io cluster --type=merge --patch '{"spec": { "migration": { "mtu": { "network": { "from": 1400, "to": 9000 } , "machine": { "to" : 9100} } } } }'
oc patch Network.operator.openshift.io cluster --type=merge --patch \
  '{"spec": { "migration": null, "defaultNetwork":{ "ovnKubernetesConfig": { "mtu": 8900 }}}}'
```

## REF

- <https://blog.maumene.org/2020/11/18/OKD-or-OpenShit-in-one-box.html>
- <https://cgruver.github.io/okd4-single-node-cluster/>
- <https://github.com/cragr/okd4_files>
- <https://github.com/openshift/okd/blob/master/Guides/UPI/libvirt/libvirt.md>
- <https://medium.com/swlh/guide-okd-4-5-single-node-cluster-832693cb752b>
- <https://itnext.io/guide-installing-an-okd-4-5-cluster-508a2631cbee>
- <https://www.openshift.com/blog/guide-to-installing-an-okd-4-4-cluster-on-your-home-lab>
- <https://github.com/openshift/okd/issues/963>
- <https://www.haproxy.com/blog/use-the-proxy-protocol-to-preserve-a-clients-ip-address/>
- <https://amd64.origin.releases.ci.openshift.org/#4-stable>
