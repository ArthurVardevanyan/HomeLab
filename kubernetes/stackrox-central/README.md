# Stackrox Central

```bash
kubectl create ns stackrox

# Host Cluster
export ADMIN_PASSWORD="$(vault kv get --field=admin-password secret/homelab/stackrox/common)"

helm template -n stackrox --include-crds --create-namespace stackrox-central-services stackrox/stackrox-central-services \
 --set imagePullSecrets.allowNone=true --set central.exposure.route.enabled=true --set env.openshift=4 \
 --set central.adminPassword.value="${ADMIN_PASSWORD}" --set image.registry="quay.io/stackrox-io" \
 --set central.db.external=true --set central.db.password.value="<path:secret/data/homelab/stackrox/db#password>" \
 --set central.persistence.none=true \
 --set central.db.source.connectionString="host=stackrox-primary.postgres.svc port=5432 dbname=stackrox user=stackrox" \
   >/tmp/central.yaml

kubectl -n stackrox exec deploy/central -- roxctl --insecure-skip-tls-verify \
 --password "${ADMIN_PASSWORD}" \
 central init-bundles generate stackrox-init-bundle --output - >stackrox-init-bundle.yaml

kubectl kustomize kubernetes/stackrox-central/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Renewing the Central TLS certificate

The `central-tls` secret is sourced from Vault via External Secrets Operator
(`base/secret.yaml`). When Central reports its service certificate is about to
expire, generate a renewed secret and push the PEMs back into Vault.

Vault properties consumed by the `central-tls` ExternalSecret:

| PEM (secret key) | Vault path                 | Property                  |
| ---------------- | -------------------------- | ------------------------- |
| `ca.pem`         | `homelab/stackrox/common`  | `ca-pem`                  |
| `ca-key.pem`     | `homelab/stackrox/central` | `central-tls-ca-key-pem`  |
| `jwt-key.pem`    | `homelab/stackrox/central` | `central-tls-jwt-key-pem` |
| `cert.pem`       | `homelab/stackrox/central` | `central-tls-cert-pem`    |
| `key.pem`        | `homelab/stackrox/central` | `central-tls-key-pem`     |

```bash
export KUBECONFIG="$HOME/.kube/okd"

# 1. Generate a renewed central-tls secret from the running Central and save it.
#    (Central's cert-rotation writes a fresh Secret; export it to a file.)
kubectl -n stackrox get secret central-tls -o yaml >/tmp/central-tls.yaml

# 2. Extract each PEM from the renewed secret.
for k in ca.pem ca-key.pem jwt-key.pem cert.pem key.pem; do
  kubectl -n stackrox get secret central-tls -o "jsonpath={.data.${k//./\\.}}" \
    | base64 -d >"/tmp/${k}"
done

# 3. Push the renewed PEMs into Vault (KV v2 mount "secret").
vault kv patch secret/homelab/stackrox/common \
  ca-pem=@/tmp/ca.pem

vault kv patch secret/homelab/stackrox/central \
  central-tls-ca-key-pem=@/tmp/ca-key.pem \
  central-tls-jwt-key-pem=@/tmp/jwt-key.pem \
  central-tls-cert-pem=@/tmp/cert.pem \
  central-tls-key-pem=@/tmp/key.pem

# 4. Force ESO to re-sync and roll Central to pick up the new cert.
kubectl -n stackrox annotate externalsecret central-tls \
  force-sync="$(date +%s)" --overwrite
kubectl -n stackrox rollout restart deploy/central

# 5. Verify the new expiry.
kubectl -n stackrox get secret central-tls -o jsonpath='{.data.cert\.pem}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```

> **Rolling secured-cluster pods (sensor / collector / admission-control):**
> Only required if the **CA** (`homelab/stackrox/common#ca-pem`) changed, since
> those components trust Central via the CA — not its leaf cert. Renewing only
> Central's leaf `cert.pem` (CA unchanged) does **not** require a secured-side
> restart. If you rotate the CA, or the secured components' own leaf certs
> (`sensor-tls`, `collector-tls`, `admission-control-tls`) are expiring, also run:
>
> ```bash
> kubectl -n stackrox rollout restart deploy/sensor deploy/admission-control ds/collector
> ```

## Renewing the Scanner / Scanner-V4 TLS certificates

Unlike Central's leaf cert, the **scanner service leaf certs do not
auto-rotate**. They are all signed by the StackRox CA (`common#ca-pem`, valid
until 2030) and share the same 1-year lifetime, so they expire together. Symptom
when expired:

```text
scanner-v4 indexer panic: migrate: failed to connect ... scanner-v4-db.stackrox.svc:
tls: failed to verify certificate: x509: certificate has expired
```

Reissue the leaf certs from the existing CA (no CA rotation needed).

Vault properties consumed by the scanner ExternalSecrets (`base/secret.yaml`):

| Secret                   | Vault path                    | cert / key properties                  |
| ------------------------ | ----------------------------- | -------------------------------------- |
| `scanner-tls`            | `homelab/stackrox/central`    | `scanner-tls-cert-pem` / `-key-pem`    |
| `scanner-db-tls`         | `homelab/stackrox/central`    | `scanner-db-tls-cert-pem` / `-key-pem` |
| `scanner-v4-db-tls`      | `homelab/stackrox/scanner-v4` | `db-tls-cert` / `db-tls-key`           |
| `scanner-v4-indexer-tls` | `homelab/stackrox/scanner-v4` | `indexer-tls-cert` / `indexer-tls-key` |
| `scanner-v4-matcher-tls` | `homelab/stackrox/scanner-v4` | `matcher-tls-cert` / `matcher-tls-key` |

```bash
export KUBECONFIG="$HOME/.kube/okd"
cd /tmp

# 1. Pull the still-valid CA cert + key (from the central-tls secret).
kubectl -n stackrox get secret central-tls -o jsonpath='{.data.ca\.pem}'     | base64 -d > ca.pem
kubectl -n stackrox get secret central-tls -o jsonpath='{.data.ca-key\.pem}' | base64 -d > ca-key.pem
openssl x509 -in ca.pem -noout -enddate   # confirm CA is not expired

# 2. Generate a fresh leaf cert for each scanner service, matching CN + SANs.
gen_cert() {
  local name="$1" cn="$2" dns="$3"
  openssl genrsa -out "${name}-key.pem" 4096
  openssl req -new -key "${name}-key.pem" -out "${name}.csr" -subj "/CN=${cn}"
  cat > "${name}.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${dns}
EOF
  openssl x509 -req -in "${name}.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -out "${name}-cert.pem" -days 365 -sha256 -extfile "${name}.ext"
  openssl verify -CAfile ca.pem "${name}-cert.pem"
}

gen_cert scanner-v4-db      "SCANNER_V4_DB_SERVICE: Scanner V4 DB" \
  "DNS:scanner-v4-db.stackrox,DNS:scanner-v4-db.stackrox.svc,DNS:scanner-v4-db.stackrox.svc.cluster.local"
gen_cert scanner-v4-indexer "SCANNER_V4_INDEXER_SERVICE: Scanner V4 Indexer" \
  "DNS:scanner-v4-indexer.stackrox,DNS:scanner-v4-indexer.stackrox.svc,DNS:scanner-v4-indexer.stackrox.svc.cluster.local"
gen_cert scanner-v4-matcher "SCANNER_V4_MATCHER_SERVICE: Scanner V4 Matcher" \
  "DNS:scanner-v4-matcher.stackrox,DNS:scanner-v4-matcher.stackrox.svc,DNS:scanner-v4-matcher.stackrox.svc.cluster.local"

# 3. Push the fresh certs into Vault (requires: vault login).
vault kv patch secret/homelab/stackrox/scanner-v4 \
  db-tls-cert=@scanner-v4-db-cert.pem           db-tls-key=@scanner-v4-db-key.pem \
  indexer-tls-cert=@scanner-v4-indexer-cert.pem indexer-tls-key=@scanner-v4-indexer-key.pem \
  matcher-tls-cert=@scanner-v4-matcher-cert.pem matcher-tls-key=@scanner-v4-matcher-key.pem

# 4. Force ESO re-sync, then roll scanner-v4 (DB first).
for es in scanner-v4-db-tls scanner-v4-indexer-tls scanner-v4-matcher-tls; do
  kubectl -n stackrox annotate externalsecret "$es" force-sync="$(date +%s)" --overwrite
done
kubectl -n stackrox rollout restart deploy/scanner-v4-db
kubectl -n stackrox rollout status  deploy/scanner-v4-db
kubectl -n stackrox rollout restart deploy/scanner-v4-indexer deploy/scanner-v4-matcher

# 5. Verify the new expiry.
kubectl -n stackrox get secret scanner-v4-db-tls -o jsonpath='{.data.cert\.pem}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```

> The same `gen_cert` flow applies to the Scanner v2 certs (`scanner-tls`,
> `scanner-db-tls`) — generate with CN `SCANNER_SERVICE: Scanner` /
> `SCANNER_DB_SERVICE: Scanner DB` and SANs `scanner[-db].stackrox[.svc...]`,
> then patch the `central#scanner-*-tls-*-pem` properties and roll
> `deploy/scanner` + `deploy/scanner-db`.
