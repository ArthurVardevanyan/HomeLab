# phpMyAdmin

```bash
kubectl kustomize kubernetes/phpmyadmin/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://artifacthub.io/packages/helm/bitnami/phpmyadmin>
- <https://askubuntu.com/questions/763336/cannot-enter-phpmyadmin-as-root-mysql-5-7>
- <https://computingforgeeks.com/install-phpmyadmin-with-apache-on-debian-10-buster/>
- <https://stackoverflow.com/questions/3958615/import-file-size-limit-in-phpmyadmin>
