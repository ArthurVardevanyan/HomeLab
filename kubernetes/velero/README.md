# Velero

```bash
helm template velero --include-crds vmware-tanzu/velero \
--namespace velero \
--create-namespace \
--set-file credentials.secretContents.cloud=/home/arthur/Projects/Code/HomeLab/notes/truenas-s3.yaml \
--set configuration.backupStorageLocation[0].name=velero-backup \
--set configuration.backupStorageLocation[0].provider=aws \
--set configuration.backupStorageLocation[0].bucket=velero-backup \
--set configuration.backupStorageLocation[0].config.region=homelab \
--set configuration.backupStorageLocation[0].config.s3Url=http://10.0.0.3:9000 \
--set configuration.volumeSnapshotLocation[0].name=velero-snapshot \
--set configuration.volumeSnapshotLocation[0].provider=aws \
--set configuration.volumeSnapshotLocation[0].config.region=homelab \
--set configuration.volumeSnapshotLocation[0].config.s3Url=http://10.0.0.3:9000  \
--set initContainers[0].name=velero-plugin-for-aws \
--set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.2 \
--set initContainers[0].volumeMounts[0].mountPath=/target \
--set initContainers[0].volumeMounts[0].name=plugins \
--set initContainers[0].name=velero-plugin-for-aws \
--set initContainers[1].name=velero-plugin-for-csi \
--set initContainers[1].image=velero/velero-plugin-for-csi:v0.7.0  \
--set initContainers[1].volumeMounts[0].mountPath=/target \
--set initContainers[1].volumeMounts[0].name=plugins \
--set deployNodeAgent=true \
--set uploaderType=kopia \
--set features="EnableCSI," \
--set upgradeCRDs=false > dump.yaml
```

## Ref

- <https://artifacthub.io/packages/helm/vmware-tanzu/velero>
- <https://velero.io/docs/v1.13/csi/>
