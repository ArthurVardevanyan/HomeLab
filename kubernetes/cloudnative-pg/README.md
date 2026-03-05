# CloudNativePG

> [!CAUTION]
> CNPG manages instance pods directly without a Deployment or StatefulSet.
> If the operator is down and a pod is evicted, no controller will recreate it
> until the operator recovers. Automated failover also requires the operator to
> be running. Ensure the operator runs with multiple replicas and anti-affinity.

```bash
kubectl kustomize kubernetes/cloudnative-pg/overlays/okd | kubectl apply -f - --server-side
```

## REF

- <https://cloudnative-pg.io/docs/>
- <https://github.com/cloudnative-pg/cloudnative-pg>

## Migrating from Crunchy Postgres (PGO) to CNPG

### Prerequisites

- CNPG operator is running and healthy
- The new CNPG `Cluster` resource is deployed and the bootstrap has completed
- The Crunchy PostgresCluster is still running and accessible

### Variables

```bash
NAMESPACE=quay
CLUSTER=quay
DB_NAME=quay
DB_USER=quay
APP_DEPLOYMENT=quay
```

### 1. Scale down the application

Stop the application so no new writes hit the old database.

```bash
kubectl scale deployment "$APP_DEPLOYMENT" -n "$NAMESPACE" --replicas=0
```

### 2. Identify the Crunchy primary pod

```bash
CRUNCHY_PRIMARY=$(kubectl get pods -n "$NAMESPACE" \
  -l postgres-operator.crunchydata.com/cluster="$CLUSTER",postgres-operator.crunchydata.com/role=master \
  -o jsonpath='{.items[0].metadata.name}')
echo "$CRUNCHY_PRIMARY"
```

### 3. Dump the database from Crunchy

> [!NOTE]
> `PGOPTIONS='-c statement_timeout=0'` prevents the connection being killed
> mid-dump on large tables (e.g. `geodata_places`).

```bash
kubectl exec -n "$NAMESPACE" -it "$CRUNCHY_PRIMARY" -c database -- \
  bash -c "PGOPTIONS='-c statement_timeout=0' pg_dump -h 127.0.0.1 -U \"$DB_USER\" -d \"$DB_NAME\" -Fc -f /tmp/dump.db"
```

### 4. Copy the dump to the CNPG primary pod

```bash
# Identify the CNPG primary
CNPG_PRIMARY=$(kubectl get pods -n "$NAMESPACE" \
  -l cnpg.io/cluster="$CLUSTER",role=primary \
  -o jsonpath='{.items[0].metadata.name}')
echo "$CNPG_PRIMARY"

# Copy from Crunchy to local
kubectl cp -n "$NAMESPACE" -c database "$CRUNCHY_PRIMARY":/tmp/dump.db ./dump.db

# Copy from local to CNPG
kubectl cp -n "$NAMESPACE" -c postgres ./dump.db "$CNPG_PRIMARY":/run/dump.db
```

### 5. Restore into the CNPG cluster

```bash
kubectl exec -n "$NAMESPACE" -it "$CNPG_PRIMARY" -c postgres -- \
  pg_restore -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --no-privileges /run/dump.db
```

> [!NOTE]
> `--clean --if-exists` drops existing objects before restoring.
> `--no-owner --no-privileges` avoids errors from role mismatches between operators.
>
> Errors about extensions like `pg_stat_statements` or `pgaudit` are expected
> and harmless — these are managed by the operator, not the application user.

### 6. Verify the data

```bash
kubectl exec -n "$NAMESPACE" -it "$CNPG_PRIMARY" -c postgres -- \
  psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c '\dt'
```

### 7. Update the application database connection

Update the application datasource/secret to point to the new CNPG service:

```text
<cluster>-rw.<namespace>.svc:5432
```

CNPG creates three services:

| Service        | Purpose                                   |
| -------------- | ----------------------------------------- |
| `<cluster>-rw` | Always points to the primary (read-write) |
| `<cluster>-ro` | Points to replicas (read-only)            |
| `<cluster>-r`  | Points to any instance (read)             |

### 8. Scale the application back up

```bash
kubectl scale deployment "$APP_DEPLOYMENT" -n "$NAMESPACE" --replicas=1
```

### 9. Cleanup

```bash
rm ./dump.db
```

### 10. Decommission the old Crunchy cluster

Once verified, remove the old PGO `PostgresCluster`:

```bash
kubectl delete postgrescluster "$CLUSTER" -n "$NAMESPACE"
```

> [!CAUTION]
> This deletes the old PVCs. Make sure the CNPG migration is fully validated
> and you have backups before deleting the Crunchy cluster.
