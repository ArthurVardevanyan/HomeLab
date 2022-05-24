#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

URL="https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/${CI_PROJECT_NAMESPACE}/${CI_PROJECT_NAME}"
JSON_STRING='{"state":"'"${STATUS}"'","description":"Pipeline '"${DESCRIPTION}"'", "context":"GitLab CI/CD"}'

curl -X POST -H "Accept: application/vnd.github.v3+json" ${URL}/statuses/${CI_COMMIT_SHA} -d "${JSON_STRING}"

# for CI_COMMIT_SHA in $(git log --format=oneline | cut -d ' ' -f 1); do
# 	curl -X POST -H "Accept: application/vnd.github.v3+json" ${URL}/statuses/${CI_COMMIT_SHA} -d "${JSON_STRING}"
# done
