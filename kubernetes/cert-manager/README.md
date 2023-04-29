# Cert Manager

```bash
kubectl kustomize kubernetes/cert-manager/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/>
- <https://community.traefik.io/t/can-i-set-namespace-for-tls-secretname-in-ingressroute/2619>
- <https://crt.sh/>
- <https://docs.openshift.com/container-platform/4.1/nodes/nodes/nodes-nodes-resources-configuring.html>
- <https://github.com/cockpit-project/cockpit/wiki/Proxying-Cockpit-over-Apache-with-LetsEncrypt>
- <https://github.com/jetstack/cert-manager/issues/2384>
- <https://it-obey.com/index.php/wildcard-certificates-dns-challenges-and-traefik-in-kubernetes/>
- <https://opensource.com/article/20/3/ssl-letsencrypt-k3s>
- <https://paraspatidar.medium.com/add-self-signed-or-ca-root-certificate-in-kubernetes-pod-ca-root-certificate-store-cb7863cb3f87>
- <https://tools.keycdn.com/ssl>
- <https://websiteforstudents.com/setup-apache2-with-http-2-and-lets-encrypt-ssl/>
- <https://www.debontonline.com/2020/12/kubernetes-part-12-deploy-heimdall-yaml.html>
- <https://www.fosstechnix.com/kubernetes-nginx-ingress-controller-letsencrypt-cert-managertls/>
