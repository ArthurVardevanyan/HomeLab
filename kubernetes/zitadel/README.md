# Zitadel

```bash
helm template zitadel zitadel/zitadel \
 --set zitadel.masterkey="<path:secret/data/homelab/zitadel/config#masterkey>" \
 --set zitadel.configmapConfig.ExternalSecure=true \
 --set zitadel.configmapConfig.ExternalDomain="zitadel.arthurvardevanyan.com" \
 --set zitadel.configmapConfig.ExternalPort="443" \
 --set zitadel.configmapConfig.TLS.Enabled=false \
 --set zitadel.configmapConfig.Database.cockroach.User.SSL.Mode="verify-full" \
 --set zitadel.configmapConfig.Database.cockroach.Admin.SSL.Mode="verify-full" \
 --set zitadel.secretConfig.Database.cockroach.User.Password="<path:secret/data/homelab/zitadel/config#db-password>" \
 --set zitadel.secretConfig.Database.cockroach.Host="crdb-public" \
 --set zitadel.dbSslCaCrtSecret=crdb-ca \
 --set zitadel.dbSslAdminCrtSecret=crdb-root \
 --set zitadel.dbSslUserCrtSecret=db-cockroachdb-zitadel-secret \
 --set zitadel.configmapConfig.FirstInstance.Org.Machine=false \
 --set setupJob.activeDeadlineSeconds=600 \
 --set pdb.enabled=true \
 --set pdb.minAvailable=1 \
 --set metrics.enabled=true \
 --set metrics.serviceMonitor.enabled=true \
 --set replicaCount=0 > zitadel.yaml
```

Manual Fixes, Remove:

```bash
runAsUser: 0
runAsUser: 1000
runAsNonRoot: false

&&  chown -R 1000:1000 /chowned-secrets/*
```

Fix Yaml's

```bash
kubectl kustomize kubernetes/zitadel/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

Initial User

```bash
zitadel-admin@zitadel.zitadel.arthurvardevanyan.com
```

Call Back URLs

```bash
https://oauth-openshift.apps.okd.homelab.arthurvardevanyan.com/oauth2callback/zitadel
https://oauth-openshift.apps.okd.virt.arthurvardevanyan.com/oauth2callback/zitadel
```

TODO: PassThrough Termination

## REF

- <https://zitadel.com/docs/self-hosting/deploy/kubernetes>
- <https://github.com/zitadel/zitadel-charts>
