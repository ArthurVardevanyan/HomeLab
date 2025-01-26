# Postgres

```bash
kubectl kustomize kubernetes/postgres/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## Image Mirroring

```bash
kubectl get pods -n postgres -o wide -o yaml | grep "developers.crunchydata.com" | sed 's/^.*: /: /' | sort -u


declare -a crunchy=(
registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4@sha256:0779211b531a5673dca64a82ab53ff31e7b1dc084ba0abf7d337dfc08ba32fcb
registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-4.30-34
registry.developers.crunchydata.com/crunchydata/crunchy-pgadmin4:ubi8-8.14-1
registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest@sha256:6eccc5607b2772115e24f280e05e0739f923d79cb3308a35605afb34c9ac8907
registry.developers.crunchydata.com/crunchydata/crunchy-pgbackrest:ubi8-2.54.1-0
registry.developers.crunchydata.com/crunchydata/crunchy-pgbouncer:ubi8-1.23-3
registry.developers.crunchydata.com/crunchydata/crunchy-postgres-exporter@sha256:09cd036714b38620bfc8ee9280eee0b249c9afc84ab7fa6be23175d3a78da6af
registry.developers.crunchydata.com/crunchydata/crunchy-postgres-exporter:ubi8-0.16.0-0
registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-15.10-3.3-2
registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-16.6-3.4-2
registry.developers.crunchydata.com/crunchydata/crunchy-postgres-gis:ubi8-17.2-3.4-2
registry.developers.crunchydata.com/crunchydata/crunchy-postgres@sha256:e15246402147a57d131de37e12a66264e56eb8e4336650f7febcbc8635162555
registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.10-2
registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-16.6-2
registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-17.2-2
registry.developers.crunchydata.com/crunchydata/crunchy-upgrade:ubi8-5.7.3-0
registry.developers.crunchydata.com/crunchydata/postgres-operator@sha256:36a4f724fd9696717ad96f72aea827a352093ba2487954c471d1797e3813711d
registry.developers.crunchydata.com/crunchydata/postgres-operator:ubi8-5.7.3-0
)

for src in "${crunchy[@]}"; do
  suffix="${src##*/}"
  srcImg=$(echo "${suffix}" | cut -d ':' -f1)
  srcTag=$(echo "${suffix}" | cut -d ':' -f2)

  echo "${src} .."
  skopeo copy --override-os linux --override-arch amd64 \
    docker://"${src}" \
    docker://registry.arthurvardevanyan.com/crunchydata/"${srcImg}:${srcTag}"
done
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
