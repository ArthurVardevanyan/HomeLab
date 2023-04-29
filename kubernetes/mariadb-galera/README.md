# MariaDB Galera

```bash
kubectl kustomize kubernetes/mariadb-galera/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://mariadb.com/kb/en/what-is-mariadb-galera-cluster/>
- <https://www.symmcom.com/docs/how-tos/databases/how-to-recover-mariadb-galera-cluster-after-partial-or-full-crash>
- <https://www.devopszones.com/2020/08/how-to-check-status-of-mariadb-galera.html>
- <https://dba.stackexchange.com/questions/208612/how-do-i-disable-mysql-on-linux-from-starting-on-boot-or-statup>
- <https://stackoverflow.com/questions/16747035/how-do-i-create-a-user-with-root-privileges-in-mysql-mariadb>
- <https://websiteforstudents.com/allow-remote-access-to-mariadb-database-server-on-ubuntu-18-04/>
- <https://mariadb.com/kb/en/galera-cluster-system-variables/#wsrep_mode>
