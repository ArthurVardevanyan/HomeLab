#!/bin/bash

set -o errexit  # exit on any failure
set -o nounset  # exit on undeclared variables
set -o pipefail # return value of all commands in a pipe
shopt -s failglob

# scripts.sh
#
# Reissue expired StackRox service leaf certificates from the existing (still
# valid) StackRox CA and push them into Vault, where External Secrets Operator
# syncs them back into the cluster.
#
# Background:
#   - All StackRox service leaf certs (central, scanner, scanner-v4) share the
#     same 1-year lifetime and expire together. The CA (common#ca-pem) is valid
#     until 2030.
#   - The RHACS UI "renew certificate" bundle only covers central-tls; the
#     scanner certs must be regenerated manually.
#   - Certs are sourced from Vault via ESO, so renewed certs must be written to
#     Vault (not kubectl apply'd, which ESO would revert).
#
# Requirements: kubectl/oc, openssl, vault (already `vault login`'d).
#
# Usage:
#   export KUBECONFIG="$HOME/.kube/okd"
#   vault login ...
#   ./kubernetes/stackrox-central/scripts.sh [central|scanner-v4|scanner|all]
#
# Targets:
#   central    Push Central's (auto-rotated) central-tls PEMs into Vault and
#              roll Central. Central rotates its own leaf cert into the live
#              secret; this only mirrors it into Vault so ESO does not revert it.
#              Optionally sourced from a downloaded RHACS bundle via
#              CENTRAL_TLS_FILE=/path/to/central-tls.yaml
#   scanner-v4 (default) Reissue scanner-v4 leaf certs from the CA.
#   scanner    Reissue scanner (v2) + scanner-db leaf certs from the CA.
#   all        central + scanner + scanner-v4.
#
# Default target: scanner-v4

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

NAMESPACE="stackrox"
WORKDIR="$(mktemp -d /tmp/stackrox-certs.XXXXXX)"
TARGET="${1:-scanner-v4}"

log() { echo -e "${BLUE}==>${NC} $*"; }
ok() { echo -e "${GREEN}OK:${NC} $*"; }
err() {
  echo -e "${RED}ERROR:${NC} $*" >&2
  exit 1
}

cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

function preflight {
  command -v openssl >/dev/null || err "openssl not found"
  command -v vault >/dev/null || err "vault CLI not found"
  command -v kubectl >/dev/null || err "kubectl not found"
  : "${KUBECONFIG:?KUBECONFIG must be set (e.g. export KUBECONFIG=\$HOME/.kube/okd)}"
  vault token lookup >/dev/null 2>&1 || err "Vault token not valid. Run: vault login"
  ok "preflight checks passed"
}

function fetch_ca {
  log "Fetching StackRox CA from central-tls secret"
  kubectl -n "${NAMESPACE}" get secret central-tls \
    -o jsonpath='{.data.ca\.pem}' | base64 -d >"${WORKDIR}/ca.pem"
  kubectl -n "${NAMESPACE}" get secret central-tls \
    -o jsonpath='{.data.ca-key\.pem}' | base64 -d >"${WORKDIR}/ca-key.pem"

  local ca_end
  ca_end="$(openssl x509 -in "${WORKDIR}/ca.pem" -noout -enddate)"
  ok "CA loaded (${ca_end})"

  # Refuse to sign with an expired CA.
  if ! openssl x509 -in "${WORKDIR}/ca.pem" -noout -checkend 0 >/dev/null 2>&1; then
    err "StackRox CA is expired. A CA rotation / full reinstall is required."
  fi
}

# gen_cert <name> <cn> <dns-sans-csv>
function gen_cert {
  local name="$1" cn="$2" dns="$3"

  openssl genrsa -out "${WORKDIR}/${name}-key.pem" 4096 2>/dev/null
  openssl req -new -key "${WORKDIR}/${name}-key.pem" \
    -out "${WORKDIR}/${name}.csr" -subj "/CN=${cn}" 2>/dev/null

  cat >"${WORKDIR}/${name}.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${dns}
EOF

  openssl x509 -req -in "${WORKDIR}/${name}.csr" \
    -CA "${WORKDIR}/ca.pem" -CAkey "${WORKDIR}/ca-key.pem" -CAcreateserial \
    -out "${WORKDIR}/${name}-cert.pem" -days 365 -sha256 \
    -extfile "${WORKDIR}/${name}.ext" 2>/dev/null

  openssl verify -CAfile "${WORKDIR}/ca.pem" "${WORKDIR}/${name}-cert.pem" >/dev/null \
    || err "generated ${name} cert failed CA verification"
  ok "generated ${name} ($(openssl x509 -in "${WORKDIR}/${name}-cert.pem" -noout -enddate))"
}

function renew_scanner_v4 {
  log "Generating scanner-v4 leaf certificates"
  gen_cert scanner-v4-db "SCANNER_V4_DB_SERVICE: Scanner V4 DB" \
    "DNS:scanner-v4-db.${NAMESPACE},DNS:scanner-v4-db.${NAMESPACE}.svc,DNS:scanner-v4-db.${NAMESPACE}.svc.cluster.local"
  gen_cert scanner-v4-indexer "SCANNER_V4_INDEXER_SERVICE: Scanner V4 Indexer" \
    "DNS:scanner-v4-indexer.${NAMESPACE},DNS:scanner-v4-indexer.${NAMESPACE}.svc,DNS:scanner-v4-indexer.${NAMESPACE}.svc.cluster.local"
  gen_cert scanner-v4-matcher "SCANNER_V4_MATCHER_SERVICE: Scanner V4 Matcher" \
    "DNS:scanner-v4-matcher.${NAMESPACE},DNS:scanner-v4-matcher.${NAMESPACE}.svc,DNS:scanner-v4-matcher.${NAMESPACE}.svc.cluster.local"

  log "Pushing scanner-v4 certs into Vault"
  vault kv patch secret/homelab/stackrox/scanner-v4 \
    db-tls-cert=@"${WORKDIR}/scanner-v4-db-cert.pem" \
    db-tls-key=@"${WORKDIR}/scanner-v4-db-key.pem" \
    indexer-tls-cert=@"${WORKDIR}/scanner-v4-indexer-cert.pem" \
    indexer-tls-key=@"${WORKDIR}/scanner-v4-indexer-key.pem" \
    matcher-tls-cert=@"${WORKDIR}/scanner-v4-matcher-cert.pem" \
    matcher-tls-key=@"${WORKDIR}/scanner-v4-matcher-key.pem" >/dev/null
  ok "Vault updated (secret/homelab/stackrox/scanner-v4)"

  sync_and_roll \
    "scanner-v4-db-tls scanner-v4-indexer-tls scanner-v4-matcher-tls" \
    "scanner-v4-db" \
    "scanner-v4-indexer scanner-v4-matcher" \
    "scanner-v4-db-tls"
  verify_expiry scanner-v4-db-tls
}

function renew_scanner {
  log "Generating scanner (v2) leaf certificates"
  gen_cert scanner "SCANNER_SERVICE: Scanner" \
    "DNS:scanner.${NAMESPACE},DNS:scanner.${NAMESPACE}.svc,DNS:scanner.${NAMESPACE}.svc.cluster.local"
  gen_cert scanner-db "SCANNER_DB_SERVICE: Scanner DB" \
    "DNS:scanner-db.${NAMESPACE},DNS:scanner-db.${NAMESPACE}.svc,DNS:scanner-db.${NAMESPACE}.svc.cluster.local"

  log "Pushing scanner certs into Vault"
  vault kv patch secret/homelab/stackrox/central \
    scanner-tls-cert-pem=@"${WORKDIR}/scanner-cert.pem" \
    scanner-tls-key-pem=@"${WORKDIR}/scanner-key.pem" \
    scanner-db-tls-cert-pem=@"${WORKDIR}/scanner-db-cert.pem" \
    scanner-db-tls-key-pem=@"${WORKDIR}/scanner-db-key.pem" >/dev/null
  ok "Vault updated (secret/homelab/stackrox/central)"

  sync_and_roll \
    "scanner-tls scanner-db-tls" \
    "scanner-db" \
    "scanner" \
    "scanner-db-tls"
  verify_expiry scanner-db-tls
}

function renew_central {
  # Central rotates its own leaf cert into the live central-tls secret. When a
  # renewed RHACS bundle was downloaded, apply it first so the live secret holds
  # the fresh PEMs (ESO would otherwise revert a bare kubectl apply).
  if [[ -n "${CENTRAL_TLS_FILE:-}" ]]; then
    [[ -f "${CENTRAL_TLS_FILE}" ]] || err "CENTRAL_TLS_FILE not found: ${CENTRAL_TLS_FILE}"
    log "Applying downloaded bundle: ${CENTRAL_TLS_FILE}"
    kubectl -n "${NAMESPACE}" apply -f "${CENTRAL_TLS_FILE}" >/dev/null
  fi

  log "Extracting central-tls PEMs from live secret"
  local k
  for k in ca.pem ca-key.pem jwt-key.pem cert.pem key.pem; do
    kubectl -n "${NAMESPACE}" get secret central-tls \
      -o "jsonpath={.data.${k//./\\.}}" | base64 -d >"${WORKDIR}/central-${k}"
    [[ -s "${WORKDIR}/central-${k}" ]] || err "central-tls is missing ${k}"
  done

  # Refuse to mirror an expired leaf cert into Vault. If the live secret is still
  # expired, the renewed bundle was not applied - pass CENTRAL_TLS_FILE=<bundle>.
  if ! openssl x509 -in "${WORKDIR}/central-cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
    err "Live central-tls cert is expired; nothing renewed to push. Re-run with CENTRAL_TLS_FILE=<downloaded bundle> to apply the renewed cert first."
  fi
  ok "Central leaf cert is valid ($(openssl x509 -in "${WORKDIR}/central-cert.pem" -noout -enddate))"

  log "Pushing Central CA into Vault (secret/homelab/stackrox/common)"
  vault kv patch secret/homelab/stackrox/common \
    ca-pem=@"${WORKDIR}/central-ca.pem" >/dev/null

  log "Pushing central-tls PEMs into Vault (secret/homelab/stackrox/central)"
  vault kv patch secret/homelab/stackrox/central \
    central-tls-ca-key-pem=@"${WORKDIR}/central-ca-key.pem" \
    central-tls-jwt-key-pem=@"${WORKDIR}/central-jwt-key.pem" \
    central-tls-cert-pem=@"${WORKDIR}/central-cert.pem" \
    central-tls-key-pem=@"${WORKDIR}/central-key.pem" >/dev/null
  ok "Vault updated (central-tls)"

  sync_and_roll "central-tls" "central" "" "central-tls"
  verify_expiry central-tls
}

# sync_and_roll <externalsecrets> <first-deploys> <rest-deploys> [verify-secret]
function sync_and_roll {
  local externalsecrets="$1" first="$2" rest="$3" verify_secret="${4:-}" es

  log "Forcing ESO re-sync"
  for es in ${externalsecrets}; do
    kubectl -n "${NAMESPACE}" annotate externalsecret "${es}" \
      force-sync="$(date +%s)" --overwrite >/dev/null
  done

  # Wait for ESO to report the target ExternalSecrets as SecretSynced, so we do
  # not restart workloads against a stale secret.
  for es in ${externalsecrets}; do
    log "Waiting for ExternalSecret/${es} to sync"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready \
      "externalsecret/${es}" --timeout=120s >/dev/null \
      || err "ExternalSecret/${es} did not become Ready; aborting before restart"
  done

  # If a verify secret was provided, confirm its cert is not already expired
  # (i.e. Vault really holds the renewed material) before rolling.
  if [[ -n "${verify_secret}" ]]; then
    if ! kubectl -n "${NAMESPACE}" get secret "${verify_secret}" \
      -o jsonpath='{.data.cert\.pem}' | base64 -d \
      | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
      err "${verify_secret} still holds an expired cert after ESO sync; check Vault contents"
    fi
    ok "${verify_secret} now holds a valid (non-expired) cert"
  fi

  log "Rolling workloads (dependencies first: ${first})"
  # shellcheck disable=SC2086
  kubectl -n "${NAMESPACE}" rollout restart deploy ${first}
  # shellcheck disable=SC2086
  kubectl -n "${NAMESPACE}" rollout status deploy ${first} --timeout=180s

  if [[ -n "${rest}" ]]; then
    log "Rolling remaining workloads: ${rest}"
    # shellcheck disable=SC2086
    kubectl -n "${NAMESPACE}" rollout restart deploy ${rest}
  fi
}

function verify_expiry {
  local secret="$1"
  log "Verifying new expiry for ${secret}"
  kubectl -n "${NAMESPACE}" get secret "${secret}" \
    -o jsonpath='{.data.cert\.pem}' | base64 -d \
    | openssl x509 -noout -subject -enddate
}

function main {
  preflight
  fetch_ca

  case "${TARGET}" in
    central) renew_central ;;
    scanner-v4) renew_scanner_v4 ;;
    scanner) renew_scanner ;;
    all)
      renew_central
      renew_scanner_v4
      renew_scanner
      ;;
    *) err "Unknown target '${TARGET}'. Use: central | scanner-v4 | scanner | all" ;;
  esac

  ok "Done. Target: ${TARGET}"
}

main
