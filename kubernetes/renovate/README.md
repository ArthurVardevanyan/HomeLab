# Version Checker

```bash
kubectl kustomize kubernetes/renovate/overlays/okd | argocd-vault-plugin generate - | kubectl apply -f -
```

## REF

- <https://docs.renovatebot.com/examples/self-hosting/>

## Image Audit

- **Total Unique Managed:** 17
- **Total Unique Unmanaged:** 72

## Unmanaged Images (Potential Gaps)

These images were found in files but do not appear to be managed by Renovate (no `# renovate:` comment and not a standard K8s workload).

| Image                                                                                                                                                                                         |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cuda`                                                                                                                                                                                        |
| `debian`                                                                                                                                                                                      |
| `docker.dragonflydb.io/dragonflydb/operator:v1.3.1@sha256:7410dc31c05bca2c0648fca232f2300b897f8d77f001c19d75c9647f830d768b`                                                                   |
| `docker.io/grafana/loki:2.9.15`                                                                                                                                                               |
| `docker.io/grafana/promtail:2.9.9@sha256:1ee94323aed873a5c6967656f2fa8595e7830c7d0545b46a5a7de130ae21caa5`                                                                                    |
| `docker.io/kubernetesui/dashboard:v2.7.0@sha256:ca93706ef4e400542202d620b8094a7e4e568ca9b1869c71b053cdf8b5dc3029`                                                                             |
| `docker.io/kubernetesui/metrics-scraper:v1.0.9@sha256:9b599f50dc7bfdfe71f021a4859fe19f74baf2135a8538ba1c1013832b7a66b4`                                                                       |
| `docker.io/linuxserver/unifi-network-application:8.5.6-ls68`                                                                                                                                  |
| `docker.io/longhornio/longhorn-manager:v1.7.0@sha256:02a98fe2dce45d3bcd3a56955fa5f600f63abaf43debc2ef9a81b44ce47d5ec0`                                                                        |
| `docker.io/longhornio/longhorn-share-manager:v1.7.0@sha256:83973fb06f38e07b33be9d26139089684064919a98e9d733aeddf9c504f35c0a`                                                                  |
| `docker.io/longhornio/longhorn-ui:v1.7.0@sha256:6e503a5f0ca1aa37194fade95670c93fbfb75bfeccac2f9221cecfda3fc1ca0e`                                                                             |
| `docker.io/nextcloud:32.0.2-fpm`                                                                                                                                                              |
| `docker.io/rook/ceph:master`                                                                                                                                                                  |
| `docker.io/rook/ceph:v1.18.7`                                                                                                                                                                 |
| `docker.io/velero/velero:v1.17.1@sha256:58f551f0d89a9ef1919771bdc7475c08bc1795a50a51a57b5f14316d68fc3baa`                                                                                     |
| `ghcr.io/actions/actions-runner:latest`                                                                                                                                                       |
| `ghcr.io/actions/gha-runner-scale-set-controller:0.13.0@sha256:4b98af135cd2768098fd8723ba3af4d1d7c9b4b1c3951b3649aa7a33fd4f4964`                                                              |
| `ghcr.io/chmouel/gosmee:v0.28.3@sha256:3924c4fd119281d8f0e4605e3c4354a4653d752df502ff14dc5de233b944c5e9`                                                                                      |
| `ghcr.io/external-secrets/external-secrets:v1.1.0-ubi@sha256:f27619afa57ca66cdde88ff46493cd114eb177a8f97414dcfa8a9394b959c741`                                                                |
| `ghcr.io/immich-app/immich-machine-learning:v2.3.1@sha256:379e31b8c75107b0af8141904baa8cc933d7454b88fdb204265ef11749d7d908`                                                                   |
| `ghcr.io/immich-app/immich-server:v2.3.1@sha256:f8d06a32b1b2a81053d78e40bf8e35236b9faefb5c3903ce9ca8712c9ed78445`                                                                             |
| `ghcr.io/kube-vip/kube-vip-cloud-provider:v0.0.12@sha256:f8f4e3401f7637dd55faefb35571e731a477f65d5c3f062aef73dfd31a8da596`                                                                    |
| `ghcr.io/kube-vip/kube-vip:v1.0.2@sha256:ee3702abc2daeb93399c22b14aa61aa233013f2a610e64ff3864033ebb3fedbc`                                                                                    |
| `ghcr.io/music-assistant/server:2.3.4@sha256:301cc44d2405e1f12953a44ddb65454630007755af9ada9d204bc1a3b9a06175`                                                                                |
| `ghcr.io/netbox-community/netbox:v4.4.6@sha256:150fb9808d633712a75ad57ba364fa38caab3a88d123c470967fd3b9b2f32d9c`                                                                              |
| `ghcr.io/tektoncd/operator/operator-1d69a75f22dd094880847eac907fb2c1:v0.77.0@sha256:f164d2e5e209765e2ffd267e3af9ac904645937beb84a30d19d938b6780baabf`                                         |
| `ghcr.io/tektoncd/operator/webhook-340ad78e88ca5477447aa144fedfe1a1:v0.77.0@sha256:cd4fda2a4da3cf267db09ebf75fbefdbd91e911e87556fab222be938ed2cd16d`                                          |
| `ghcr.io/tektoncd/pipeline/entrypoint-bff0a22da108bc2f16c818c97641a296:v0.65.5@sha256:a1b186d312e24963775520dfc1312d5eee0e24e29f002f0f92ea4649f8617259`                                       |
| `ghcr.io/tektoncd/pipeline/workingdirinit-0c558922ec6a1b739e550e349f2d5fc1:v0.65.5@sha256:7252b7e74cc57ffe734acc5f990f5a8f27e1142d3749c61f63239bb0c3dfe203`                                   |
| `nginx:1.29.3-bookworm@sha256:553f64aecdc31b5bf944521731cd70e35da4faed96b2b7548a3d8e2598c52a42`                                                                                               |
| `nvidia/driver`                                                                                                                                                                               |
| `quay.io/ansible/awx:24.6.1@sha256`                                                                                                                                                           |
| `quay.io/ceph/ceph:v19.2.3-20250717@sha256:af0c5903e901e329adabe219dfc8d0c3efc1f05102a753902f33ee16c26b6cee`                                                                                  |
| `quay.io/cephcsi/ceph-csi-operator:v0.4.0@sha256:5f6cc5e678cedbf2b408b61f3bd3612ff98f88521c1775853b8ded5b621d10b4`                                                                            |
| `quay.io/devfile/devworkspace-operator-index:release`                                                                                                                                         |
| `quay.io/jetstack/cert-manager-cainjector:v1.19.1@sha256:c7898aece8fb08102fca0b37683e37cb94e0a77c0d15b8e3c9128f6c04c868e0`                                                                    |
| `quay.io/jetstack/cert-manager-controller:v1.19.1@sha256:cd49e769e18ada1fd7b9a9bacc87c90db24c65cbfd4bf71694dda7ed40e91187`                                                                    |
| `quay.io/jetstack/cert-manager-package-debian:20210119.0@sha256:116133f68938ef568aca17a0c691d5b1ef73a9a207029c9a068cf4230053fed5`                                                             |
| `quay.io/jetstack/cert-manager-webhook:v1.19.1@sha256:f5bfe77541e38978aec53cc6eb924d190e1fe923c98b2582e6ccf5edf6c02cce`                                                                       |
| `quay.io/jetstack/trust-manager:v0.20.2@sha256:c446258c1ac5bcd0558802dd8db2ef490d6ecdaff4b9c9aa7e45ac73f35b20e5`                                                                              |
| `quay.io/jetstack/version-checker:v0.10.0@sha256:ea7a85422684479d0e51a41efc8edb12bed8f43aa89ab59dfea45aa92b2e8c8d`                                                                            |
| `quay.io/metallb/controller:v0.14.8@sha256:93b83b39d06bbcb0aedc0eb750c9e43e3c46dc08a6f88400ed96105224d784ec`                                                                                  |
| `quay.io/metallb/metallb-operator:0.14.2@sha256:df5a10332e70b47ada287b39b4b7fb6b5b4aac048347b938b490645e14d351f0`                                                                             |
| `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e`                                                                    |
| `quay.io/mongodb/mongodb-kubernetes-operator:0.10.0@sha256:76cd4db62ad61a15f9231ba58f1ffd7654c7b183d1e257c707a0575fd22e5ed2`                                                                  |
| `quay.io/nmstate/kubernetes-nmstate-operator:v0.85.1@sha256:55b8221fa302886b0f2a1c7d9a8198e91fc64f38a216f63c1a42e105b142cecc`                                                                 |
| `quay.io/nmstate/nmstate-console-plugin:release-1.0.0@sha256:34b2ba0a80bec7f74c3b5c5f0e4900ed0c9be1cd0ef28ee0ffdc3bcb5e7fe793`                                                                |
| `quay.io/okd/scos-release@sha256:c0467a5c0c9c4307285ca5eba1de048d3b91ded69fcbeb8044ce660d500ace7c`                                                                                            |
| `quay.io/okderators/catalog-index:testing-4.20`                                                                                                                                               |
| `quay.io/openshift/origin-oauth-proxy:4.15`                                                                                                                                                   |
| `quay.io/operator-framework/olm:v0.38.0@sha256:e5a20b421400b050a29fd0238a70b0e8f8fb8fc8a6e6153717294f7648cb403e`                                                                              |
| `quay.io/operatorhubio/catalog:latest`                                                                                                                                                        |
| `quay.io/rhobs/observability-operator-catalog:latest`                                                                                                                                         |
| `quay.io/stackrox-io/collector:4.9.1@sha256:701a6166dbc38116587ec48c5c808a0545b342298f1b3fdcc45357f0a4baff86`                                                                                 |
| `quay.io/stackrox-io/main:4.9.1@sha256:e042fb64ffe0a030baf0b8691a6aaa62d3e2b624bdced73ccdc6b4db7f69f7b5`                                                                                      |
| `quay.io/stackrox-io/scanner-db:4.9.1@sha256:00d87b4bd33774834595adc6c19affe4fd61344d4cbab9222a45842cedd86ed9`                                                                                |
| `quay.io/stackrox-io/scanner-slim:4.9.1@sha256:1dc3585a2a6ff8b061a422411409fc82d20b06da0c75c6209630d16f40eb445c`                                                                              |
| `quay.io/stackrox-io/scanner-v4-db:4.9.1@sha256:6ccd6e64082d07b0646942113f9d1dd0e47c0365d879620b3b611712e8b91a8f`                                                                             |
| `quay.io/stackrox-io/scanner-v4:4.9.1@sha256:da198a150e1eb3b1cbff1ce83fe6a4e575f1d4031b269a281fcd091b28c52522`                                                                                |
| `quay.io/stackrox-io/scanner:4.9.1@sha256:2a2e1b9a8f8bc4db9249c7fdecdd70497e73a4b806c79db5cae57681d6fec4bc`                                                                                   |
| `reg.kyverno.io/kyverno/kyverno:v1.16.0@sha256:2fad29572e08010884f0f89792af2c734fdf401c850dbeb1b610822980d9afdf`                                                                              |
| `reg.kyverno.io/kyverno/kyvernopre:v1.16.0@sha256:65265d5012b9630bd4387d5eef1d58fa30c0cfad7ace485969e8da8d465bc128`                                                                           |
| `registry.access.redhat.com/redhat/community-operator-index:v4.20`                                                                                                                            |
| `registry.arthurvardevanyan.com/homelab/argocd-operator@sha256:dc73eb66228dd189d2b672e04b78767a6f06220b92e68bbac2b2674f89766754`                                                              |
| `registry.arthurvardevanyan.com/homelab/toolbox:not_latest`                                                                                                                                   |
| `registry.arthurvardevanyan.com/homelab/udi:latest`                                                                                                                                           |
| `registry.arthurvardevanyan.com/quay/container-security-operator-index@sha256:d86a998ecafa7cff7554df6b9c1075edb7b2d99a1018cf803c8cd8060068ac0c`                                               |
| `registry.k8s.io/external-dns/external-dns:v0.19.0@sha256:ddc7f4212ed09a21024deb1f470a05240837712e74e4b9f6d1f2632ff10672e7`                                                                   |
| `registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v4.15.0-202510211321.p2.g68c4ba0.assembly.stream.el9@sha256:1bcf749fb1415d8d99d1352d8a917085d96a6390b32cbb7e6d62489404dd2e75` |
| `registry.redhat.io/redhat/certified-operator-index:v4.20`                                                                                                                                    |
| `registry.redhat.io/redhat/redhat-operator-index:v4.19`                                                                                                                                       |
| `registry.redhat.io/redhat/redhat-operator-index:v4.20`                                                                                                                                       |

## Managed Images

| Image                                                                                                                                                      |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docker.dragonflydb.io/dragonflydb/dragonfly:v1.35.1@sha256:af7f7f1143269c7ffe4128451dff8f8fc09e157d885abcc9bafeec832d2928e6`                              |
| `docker.io/ekofr/pihole-exporter:v1.2.0@sha256:242c53ef3c24b88fcbe8184390b456d05604bd50de5732ca3fd3eb24395585b3`                                           |
| `docker.io/getmeili/meilisearch:v1.30.1@sha256:d04371d3a649d27f84d6faaa8a8cecbdc1b833ebb6466383816935b8e9c6ed2a`                                           |
| `docker.io/gitea/gitea:1.25.3-rootless@sha256:68362381faad5f237edda9cf2d81a72acb42ec52968ace3da80a1b112ddbd815`                                            |
| `docker.io/hashicorp/vault:1.21.1@sha256:f4e2687b72858a9e2160c344c9fa1ef74c07f21a89a8c00534ab64d3f187b927`                                                 |
| `docker.io/homeassistant/home-assistant:2025.12.4@sha256:75ef6851d2e48d366764cdb6b569b7ad8be77dcc8e0d1b9aa508ac90e42d4c58`                                 |
| `docker.io/prom/blackbox-exporter:v0.28.0@sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc`                                         |
| `docker.io/prom/node-exporter:v1.10.2@sha256:3ac34ce007accad95afed72149e0d2b927b7e42fd1c866149b945b84737c62c3`                                             |
| `docker.io/prom/prometheus:v3.8.1@sha256:2b6f734e372c1b4717008f7d0a0152316aedd4d13ae17ef1e3268dbfaf68041b`                                                 |
| `ghcr.io/actions/actions-runner:2.330.0@sha256:ee54ad8776606f29434f159196529b7b9c83c0cb9195c1ff5a7817e7e570dcfe`                                           |
| `ghcr.io/zitadel/zitadel:v4.7.6@sha256:182c062408cae95fa7cfe6995bd8f0372770c1694a2ad6b5245042b629c1f983`                                                   |
| `quay.io/centos/centos:stream10`                                                                                                                           |
| `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e`                                 |
| `quay.io/thanos/thanos:v0.40.1@sha256:aae7b2b030ed00d88abd8c5a357d08b46f22151ca0d50d9c796223fa332389c8`                                                    |
| `registry.arthurvardevanyan.com/homelab/kube-eagle:v1.2.2@sha256:5bde9f6749c5d5b9208e6f396b503e788b49f8e95b9a596a82ea28e91f942f88`                         |
| `registry.arthurvardevanyan.com/homelab/openshift-monitoring-cr-controller:v2.3.3@sha256:17c0c9d1f17f0bb380f818dafb89526e3f8c9106675726dee705304bedefc51c` |
| `registry.k8s.io/metrics-server/metrics-server:v0.8.0@sha256:89258156d0e9af60403eafd44da9676fd66f600c7934d468ccc17e42b199aee2`                             |
