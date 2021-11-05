#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

URL="https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/ArthurVardevanyan/HomeLab"
COMMIT=$(curl -X GET -H "Accept: application/vnd.github.v3+json" ${URL}/git/refs/heads/production)
COMMIT=$(echo ${COMMIT} | jq -r '.object.sha')

JSON_STRING='{"state":"'"${STATUS}"'","description":"Pipeline '"${DESCRIPTION}"'", "context":"GitLab CI/CD"}'

curl -X POST -H "Accept: application/vnd.github.v3+json" ${URL}/statuses/${COMMIT} \
	-d "${JSON_STRING}"
