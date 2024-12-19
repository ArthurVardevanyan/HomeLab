# Postgres

```bash
kubectl kustomize kubernetes/postgres/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Image Mirroring

```bash
kubectl get pods -n postgres -o wide -o yaml | grep "developers.crunchydata.com" | sed 's/^.*: /: /' | sort -u

skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4@sha256:ca4963804ad485ac3e16986fc8be01d251d2ac4d34d4269ad1a305b7257b93b0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgadmin4@sha256:ca4963804ad485ac3e16986fc8be01d251d2ac4d34d4269ad1a305b7257b93b0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-4.30-29 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgadmin4:ubi8-4.30-29
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-4.30-33 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgadmin4:ubi8-4.30-33
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-8.10-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgadmin4:ubi8-8.10-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-8.14-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgadmin4:ubi8-8.14-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest@sha256:5fc5d790670e8a1dfd8ab245021158f4fbbe40e7071b2c12bceac848b2add28d docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgbackrest@sha256:5fc5d790670e8a1dfd8ab245021158f4fbbe40e7071b2c12bceac848b2add28d
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest:ubi8-2.52.1-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgbackrest:ubi8-2.52.1-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest:ubi8-2.54.0-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgbackrest:ubi8-2.54.0-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgbouncer:ubi8-1.22-4 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgbouncer:ubi8-1.22-4
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-pgbouncer:ubi8-1.23-2 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-pgbouncer:ubi8-1.23-2
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-exporter@sha256:0ada6c92c2f416d50329273ed50b9dcf727a39aced04084e073ad79e6ed2d8d4 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-exporter@sha256:0ada6c92c2f416d50329273ed50b9dcf727a39aced04084e073ad79e6ed2d8d4
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-exporter:ubi8-0.15.0-10 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-exporter:ubi8-0.15.0-10
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-exporter:ubi8-0.15.0-14 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-exporter:ubi8-0.15.0-14
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-15.10-3.3-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-15.10-3.3-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-15.8-3.3-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-15.8-3.3-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-16.4-3.3-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-16.4-3.3-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-16.4-3.4-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-16.4-3.4-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-16.6-3.3-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-16.6-3.3-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-16.6-3.4-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-16.6-3.4-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-17.2-3.4-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres-gis:ubi8-17.2-3.4-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres@sha256:541fac5d9aba9c99ccebb157adf18909f517673739dddf15d9362b1e2d89c5fb docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres@sha256:541fac5d9aba9c99ccebb157adf18909f517673739dddf15d9362b1e2d89c5fb
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.10-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres:ubi8-15.10-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.8-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres:ubi8-15.8-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-16.4-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres:ubi8-16.4-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-16.6-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres:ubi8-16.6-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-17.2-1 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-postgres:ubi8-17.2-1
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-upgrade:ubi8-5.6.1-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-upgrade:ubi8-5.6.1-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/crunchy-upgrade:ubi8-5.7.2-0 docker://registry.arthurvardevanyan.com/crunchydata/crunchy-upgrade:ubi8-5.7.2-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/postgres-operator@sha256:29c8277f3332c076e4a9e8a9271ae085b72e6cf86a88d53699180262a340fe0b docker://registry.arthurvardevanyan.com/crunchydata/postgres-operator@sha256:29c8277f3332c076e4a9e8a9271ae085b72e6cf86a88d53699180262a340fe0b
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/postgres-operator:ubi8-5.6.1-0 docker://registry.arthurvardevanyan.com/crunchydata/postgres-operator:ubi8-5.6.1-0
skopeo copy docker://registry.developers.crunchydata.com/crunchydata/postgres-operator:ubi8-5.7.2-0 docker://registry.arthurvardevanyan.com/crunchydata/postgres-operator:ubi8-5.7.2-0
```

## REF

- <https://access.crunchydata.com/documentation/postgres-operator/5.3.0/guides/major-postgres-version-upgrade/>
- <https://access.crunchydata.com/documentation/postgres-operator/v5/architecture/pgadmin4/>
- <https://access.crunchydata.com/documentation/postgres-operator/v5/references/crd/>
- <https://access.crunchydata.com/documentation/postgres-operator/v5/references/crd/#postgresclusterspecmonitoring>
- <https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/backup-management/>
- <https://andreas.scherbaum.la/blog/archives/1120-Changes-to-the-public-schema-in-PostgreSQL-15-and-how-to-handle-upgrades.html>
- <https://github.com/CrunchyData/postgres-operator/blob/master/docs/content/architecture/user-management.md#custom-passwords-custom-passwords>
- <https://github.com/CrunchyData/postgres-operator/issues/3144>
- <https://www.crunchydata.com/blog/easy-major-postgresql-upgrades-using-pgo-v51>
- <https://www.cybertec-postgresql.com/en/author/cybertec_schoenig/>
- <https://www.cybertec-postgresql.com/en/error-permission-denied-schema-public/>
