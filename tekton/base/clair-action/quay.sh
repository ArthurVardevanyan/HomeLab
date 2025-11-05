#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

#################
### Variables ###
#################
export REGISTRY="registry.arthurvardevanyan.com"
export REGISTRY_CREDS="/tmp/.docker/.dockerconfigjson"
export REPO="homelab/clair-action-db"
export STORAGE="/tmp/vuln-store"
export CACHE='/tmp/vuln-store-cache'
export LAYER="${CACHE}/clair-action-db.tar.gz"
export CONFIG="${CACHE}/config.json"
export MANIFEST="${CACHE}/manifest.json"
export CREDS
export TOKEN
export CONFIG_UPLOAD_URL
export CONFIG_DIGEST
export CONFIG_SIZE
export LAYER_UPLOAD_URL
export LAYER_DIGEST
export LAYER_SIZE
export LAYER_DIFFID

mkdir -p "${CACHE}"

#######################
### Create Layer Tar ###
#######################
cd "${STORAGE}"
tar -czf "${LAYER}" .

# Compute compressed & uncompressed digests
LAYER_DIGEST=$(sha256sum "${LAYER}" | awk '{print $1}')
LAYER_DIFFID=$(gzip -dc "${LAYER}" | sha256sum | awk '{print $1}')
LAYER_SIZE=$(stat --format="%s" "${LAYER}")

###########################
### Registry Login Token ###
###########################
CREDS="$(jq --raw-output --arg REGISTRY "${REGISTRY}" '.auths[$REGISTRY].auth' "${REGISTRY_CREDS}")"
TOKEN=$(curl --silent -L -X GET -H "Authorization: Basic ${CREDS}" \
  "https://${REGISTRY}/v2/auth?service=${REGISTRY}&scope=repository:${REPO}:pull,push" \
  | jq --raw-output '.token')

###################
### config.json ###
###################
cat > "${CONFIG}" <<EOF
{
  "architecture": "amd64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:${LAYER_DIFFID}"
    ]
  },
  "history": [
    {
      "created": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
      "comment": "clair vulnerability DB layer"
    }
  ]
}
EOF

CONFIG_DIGEST=$(sha256sum "${CONFIG}" | awk '{print $1}')
CONFIG_SIZE=$(stat --format="%s" "${CONFIG}")

CONFIG_UPLOAD_URL=$(curl --silent -X POST \
  "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Length: 0" -D - |
  grep -Fi Location | awk '{print $2}' | tr -d '\r')

curl --silent -X PUT -H "Content-Type: application/octet-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-binary @"${CONFIG}" \
  "${CONFIG_UPLOAD_URL}?digest=sha256:${CONFIG_DIGEST}"

#############
### layer ###
#############
LAYER_UPLOAD_URL=$(curl --silent -X POST \
  "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Length: 0" -D - |
  grep -Fi Location | awk '{print $2}' | tr -d '\r')

curl --silent -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/vnd.docker.image.rootfs.diff.tar.gzip" \
  --data-binary @"${LAYER}" \
  "${LAYER_UPLOAD_URL}?digest=sha256:${LAYER_DIGEST}"

################
### Manifest ###
################
cat > "${MANIFEST}" <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": ${CONFIG_SIZE},
    "digest": "sha256:${CONFIG_DIGEST}"
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": ${LAYER_SIZE},
      "digest": "sha256:${LAYER_DIGEST}"
    }
  ]
}
EOF

curl --silent -X PUT \
  -H "Content-Type: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-binary @"${MANIFEST}" \
  "https://${REGISTRY}/v2/${REPO}/manifests/latest"
