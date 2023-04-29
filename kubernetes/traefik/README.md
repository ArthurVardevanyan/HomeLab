# Traefik

```bash
kubectl kustomize kubernetes/traefik/overlays/k3s | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://blog.zachinachshon.com/traefik-ingress/>
- <https://doc.traefik.io/traefik/routing/routers/>
- <https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/>
- <https://github.com/k3s-io/k3s/issues/1160>
- <https://doc.traefik.io/traefik/getting-started/install-traefik/>
- <https://grafana.com/grafana/dashboards/4475>
- <https://it-obey.com/index.php/wildcard-certificates-dns-challenges-and-traefik-in-kubernetes/>
- <https://community.traefik.io/t/can-i-set-namespace-for-tls-secretname-in-ingressroute/2619>
- <https://stackoverflow.com/questions/64582491/traefik-dashboard-ingress-and-ingressroute-can-they-co-exist/64709491#64709491>
- <https://medium.com/@yanick.witschi/automated-kubernetes-deployments-with-gitlab-helm-and-traefik-4e54bec47dcf>
- <https://community.traefik.io/t/traefik-access-logs-get-real-source-ip/1213>
- <https://github.com/traefik/traefik/issues/6182>
