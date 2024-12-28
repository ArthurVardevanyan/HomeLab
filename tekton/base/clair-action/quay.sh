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
export LAYER="${CACHE}/clair-action-db.tar"
export CONFIG="${CACHE}/config.json"
export MANIFEST="${CACHE}/manifest.json"
export MATCHER_DB_DIGEST
export CREDS
export TOKEN
export CONFIG_UPLOAD_URL
export CONFIG_DIGEST
export CONFIG_SIZE
export LAYER_UPLOAD_URL
export LAYER_DIGEST
export LAYER_SIZE

####################
### Create Image ###
####################
cd "${STORAGE}"
tar -czvf "${LAYER}" .

###########################
### Quay Authentication ###
###########################
CREDS="$(jq --raw-output --arg REGISTRY "${REGISTRY}" '.auths[$REGISTRY].auth' "${REGISTRY_CREDS}")"
TOKEN=$(curl --silent -L -X GET -H "Authorization: Basic ${CREDS}" "https://${REGISTRY}/v2/auth?service=${REGISTRY}&scope=repository:${REPO}:pull,push" | jq --raw-output '.token')

###################
### config.json ###
###################
MATCHER_DB_DIGEST=$(sha256sum /tmp/vuln-store/matcher.db | awk '{print $1}')
echo "{\"architecture\":\"amd64\",\"os\":\"linux\",\"history\":[{\"created\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"author\":\"\",\"created_by\":\"\",\"comment\":\"\",\"empty_layer\":true}],\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:${MATCHER_DB_DIGEST}\"]}}" >"${CONFIG}"

CONFIG_UPLOAD_URL=$(curl --silent -X POST "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" \
	-H "Authorization: Bearer ${TOKEN}" -H "Content-Length: 0" -D - | grep -Fi Location | awk '{print $2}' | tr -d '\r')

CONFIG_DIGEST=$(sha256sum "${CONFIG}" | awk '{print $1}')
CONFIG_SIZE=$(stat --format="%s" "${CONFIG}")

curl --silent -X PUT -H "Content-Type: application/octet-stream" \
	-H "Authorization: Bearer ${TOKEN}" \
	--data-binary @"${CONFIG}" "${CONFIG_UPLOAD_URL}?digest=sha256:${CONFIG_DIGEST}"

#############
### layer ###
#############
LAYER_UPLOAD_URL=$(curl --silent -X POST "https://${REGISTRY}/v2/${REPO}/blobs/uploads/" \
	-H "Authorization: Bearer ${TOKEN}" -H "Content-Length: 0" -D - | grep -Fi Location | awk '{print $2}' | tr -d '\r')

LAYER_DIGEST=$(sha256sum "${LAYER}" | awk '{print $1}')
LAYER_SIZE=$(stat --format="%s" "${LAYER}")

curl --silent -X PUT "${LAYER_UPLOAD_URL}?digest=sha256:${LAYER_DIGEST}" \
	-H "Authorization: Bearer ${TOKEN}" \
	-H "Content-Type: application/x-tar" \
	--data-binary @"${LAYER}"

################
### Manifest ###
################
echo "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.docker.distribution.manifest.v2+json\",\"config\":{\"mediaType\":\"application/vnd.docker.container.image.v1+json\",\"size\":${CONFIG_SIZE},\"digest\":\"sha256:${CONFIG_DIGEST}\"},\"layers\":[{\"mediaType\":\"application/vnd.docker.image.rootfs.diff.tar.gzip\",\"size\":${LAYER_SIZE},\"digest\":\"sha256:${LAYER_DIGEST}\"}]}" >"${MANIFEST}"

curl --silent -X PUT -H "Content-Type: application/vnd.docker.distribution.manifest.v2+json" \
	-H "Authorization: Bearer ${TOKEN}" \
	--data-binary @"${MANIFEST}" \
	"https://${REGISTRY}/v2/${REPO}/manifests/latest"
