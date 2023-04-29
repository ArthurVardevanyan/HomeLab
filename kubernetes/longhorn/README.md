# Longhorn

```bash
export OVERLAY=k3s
export OVERLAY=okd-sandbox
export OVERLAY=okd

kubectl kustomize kubernetes/longhorn/overlays/"${OVERLAY}" | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://github.com/longhorn/longhorn/pull/5004>
- <https://longhorn.io/kb/tip-only-use-storage-on-a-set-of-nodes/>
- <https://longhorn.io/blog/longhorn-v1.1.0/.>
- <https://longhorn.io/docs/1.2.2/deploy/uninstall/>
- <https://github.com/longhorn/longhorn/wiki/Roadmap>
- <https://github.com/longhorn/longhorn/issues/1831>
- <https://github.com/longhorn/longhorn/issues/1631>
- <https://github.com/longhorn/longhorn/issues/1757>
- <https://github.com/longhorn/longhorn/pull/2909>
- <https://github.com/longhorn/longhorn>
- <https://longhorn.io/kb/troubleshooting-open-iscsi-on-rhel/>
- <https://longhorn.io/kb/troubleshooting-volumes-stuck-in-attach-detach-loop-when-using-longhorn-on-okd/>
- <https://longhorn.io/docs/1.4.1/advanced-resources/default-disk-and-node-config/>
