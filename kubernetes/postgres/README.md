# Postgres

```bash
kubectl kustomize kubernetes/postgres/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
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
