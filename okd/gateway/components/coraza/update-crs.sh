#!/usr/bin/env bash
# update-crs.sh — Regenerates OWASP CRS ConfigMaps and Secret from source.
#                 Optionally updates recommended-conf from corazawaf/coraza.
#
# Supports three sources:
#   - wasm (default): coraza-proxy-wasm repo — rules pre-validated for WASM runtime
#   - crs:            coreruleset/coreruleset repo — official CRS releases (newer versions)
#   - coraza:         corazawaf/coraza repo — updates recommended-conf only
#
# Rules are written directly under components/coraza/rules/owasp-crs/.
# All existing per-rule directories are replaced in-place.
#
# Usage:
#   ./update-crs.sh [--source wasm|crs|coraza] [--commit <sha>] [--tag <tag>]
#                   [--repo-url <url>]
#
# Examples:
#   ./update-crs.sh                                    # Latest release from coraza-proxy-wasm
#   ./update-crs.sh --source crs --tag v4.26.0        # Official CRS release tag
#   ./update-crs.sh --source wasm --commit abc1234    # Specific WASM plugin commit
#   ./update-crs.sh --source coraza --tag v3.3.0      # Update recommended-conf from coraza

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/rules"
OWASP_CRS_DIR="${RULES_DIR}/owasp-crs"
CRS_SETUP_DIR="${RULES_DIR}/crs-setup"
RECOMMENDED_CONF_DIR="${RULES_DIR}/recommended-conf"
SOURCE="wasm"
REPO_URL=""
CLONE_DIR=""
COMMIT=""
TAG=""
NAMESPACE="openshift-ingress"

# Source repository URLs
WASM_REPO_URL="https://github.com/networking-incubator/coraza-proxy-wasm.git"
CRS_REPO_URL="https://github.com/coreruleset/coreruleset.git"
CORAZA_REPO_URL="https://github.com/corazawaf/coraza.git"

# Response body rules disabled — not supported in Envoy WASM mode.
DISABLED_RESPONSE_RULES=(
  response-950-data-leakages
  response-951-data-leakages-sql
  response-952-data-leakages-java
  response-953-data-leakages-php
  response-954-data-leakages-iis
  response-955-web-shells
)

# ─── Parse Arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
  --source)
    SOURCE="$2"
    if [[ "${SOURCE}" != "wasm" && "${SOURCE}" != "crs" && "${SOURCE}" != "coraza" ]]; then
      echo "ERROR: --source must be 'wasm', 'crs', or 'coraza'" >&2
      exit 1
    fi
    shift 2
    ;;
  --commit)
    COMMIT="$2"
    shift 2
    ;;
  --tag)
    TAG="$2"
    shift 2
    ;;
  --repo-url)
    REPO_URL="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
    exit 0
    ;;
  *)
    echo "ERROR: Unknown option: $1" >&2
    exit 1
    ;;
  esac
done

# ─── Resolve Source URL ──────────────────────────────────────────────────────
if [[ -z "${REPO_URL}" ]]; then
  case "${SOURCE}" in
  wasm) REPO_URL="${WASM_REPO_URL}" ;;
  crs) REPO_URL="${CRS_REPO_URL}" ;;
  coraza) REPO_URL="${CORAZA_REPO_URL}" ;;
  *) ;;
  esac
fi

echo "==> Source: ${SOURCE} (${REPO_URL})"

# ─── Resolve Default Tag (latest release) ───────────────────────────────────
if [[ -z "${TAG}" && -z "${COMMIT}" ]]; then
  echo "==> No --tag or --commit specified, resolving latest release tag..."
  TAG=$(git ls-remote --tags --sort=-v:refname "${REPO_URL}" 'v*' 2>/dev/null |
    sed -n 's|.*refs/tags/\(v[0-9][0-9.]*\)$|\1|p' | head -1 || true)
  if [[ -z "${TAG}" ]]; then
    echo "    No release tags found, will clone default branch instead."
  else
    echo "    Resolved to: ${TAG}"
  fi
fi

# ─── Clone Source ────────────────────────────────────────────────────────────
CLONE_DIR="$(mktemp -d)/crs-source"
cleanup() { rm -rf "$(dirname "${CLONE_DIR}")"; }
trap cleanup EXIT

echo "==> Cloning source repository..."
if [[ -n "${TAG}" ]]; then
  git clone --depth 1 --branch "${TAG}" "${REPO_URL}" "${CLONE_DIR}"
elif [[ -n "${COMMIT}" ]]; then
  git clone "${REPO_URL}" "${CLONE_DIR}"
  git -C "${CLONE_DIR}" checkout "${COMMIT}"
else
  git clone --depth 1 "${REPO_URL}" "${CLONE_DIR}"
fi

# ─── Handle coraza source (recommended-conf only) ────────────────────────────
if [[ "${SOURCE}" == "coraza" ]]; then
  CONF_FILE="${CLONE_DIR}/coraza.conf-recommended"
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "ERROR: coraza.conf-recommended not found in source" >&2
    exit 1
  fi

  echo "==> Updating recommended-conf ConfigMap..."
  mkdir -p "${RECOMMENDED_CONF_DIR}"

  cat >"${RECOMMENDED_CONF_DIR}/configmap.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coraza-recommended-conf
  namespace: ${NAMESPACE}
data:
  rules: |
    # -- Coraza Engine Configuration (from coraza.conf-recommended)
$(sed -n '/^[^#]/{ s/^/    /; p; }' "${CONF_FILE}" || true)
EOF

  # Format
  if command -v prettier &>/dev/null; then
    prettier --write "${RECOMMENDED_CONF_DIR}/configmap.yaml"
  fi

  echo ""
  echo "==> Done! recommended-conf updated."
  echo "    Source: coraza (${REPO_URL})"
  echo "    Output: ${RECOMMENDED_CONF_DIR}/configmap.yaml"
  exit 0
fi

# ─── Resolve Rules Directory Based on Source ─────────────────────────────────
CRS_CONF_DIR=""
CRS_DATA_DIR=""

case "${SOURCE}" in
wasm)
  CRS_CONF_DIR="${CLONE_DIR}/wasmplugin/rules/crs"
  CRS_DATA_DIR="${CRS_CONF_DIR}"
  ;;
crs)
  CRS_CONF_DIR="${CLONE_DIR}/rules"
  CRS_DATA_DIR="${CRS_CONF_DIR}"
  ;;
*) ;;
esac

if [[ ! -d "${CRS_CONF_DIR}" ]]; then
  echo "ERROR: Rules directory not found at ${CRS_CONF_DIR}" >&2
  exit 1
fi

# ─── Detect CRS Version ─────────────────────────────────────────────────────
CRS_VERSION=""
for f in "${CRS_CONF_DIR}"/*.conf; do
  ver=$(sed -n 's/.*OWASP[_ ]CRS[/ ]ver\.\{0,1\}\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p' "${f}" 2>/dev/null | head -1 || true)
  if [[ -z "${ver}" ]]; then
    ver=$(sed -n 's/.*OWASP_CRS\/\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p' "${f}" 2>/dev/null | head -1 || true)
  fi
  if [[ -n "${ver}" ]]; then
    CRS_VERSION="${ver}"
    break
  fi
done

if [[ -z "${CRS_VERSION}" && -n "${TAG}" ]]; then
  CRS_VERSION="${TAG#v}"
fi

if [[ -z "${CRS_VERSION}" ]]; then
  echo "ERROR: Could not detect CRS version from source .conf files" >&2
  echo "       Try specifying --tag with the version (e.g., --tag v4.26.0)" >&2
  exit 1
fi
echo "==> Detected CRS version: ${CRS_VERSION}"

# ─── Remove Existing Per-Rule Dirs ───────────────────────────────────────────
echo "==> Clearing existing rule directories under ${OWASP_CRS_DIR}/..."
for d in "${OWASP_CRS_DIR}"/*/; do
  [[ -d "${d}" ]] || continue
  echo "    Removing $(basename "${d}")/"
  rm -rf "${d}"
done

# ─── Generate ConfigMaps ─────────────────────────────────────────────────────
echo "==> Generating CRS ConfigMaps..."
declare -a COMPONENT_DIRS=()

for f in "${CRS_CONF_DIR}"/*.conf; do
  [[ -e "${f}" ]] || continue
  bn=$(basename "${f}")
  case "${bn}" in
  *.example) continue ;;
  crs-setup.conf) continue ;;
  *) ;;
  esac

  cm_name="crs-$(echo "${bn}" | sed 's/\.conf$//' | tr '[:upper:]' '[:lower:]' | tr '_.' '-')"
  dir_name=$(echo "${bn}" | sed 's/\.conf$//' | tr '[:upper:]' '[:lower:]')

  mkdir -p "${OWASP_CRS_DIR}/${dir_name}"
  COMPONENT_DIRS+=("${dir_name}")

  cat >"${OWASP_CRS_DIR}/${dir_name}/configmap.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm_name}
  namespace: ${NAMESPACE}
  annotations:
    coraza.io/validation: "false"
data:
  rules: |
$(sed 's/^/    /' "${f}" || true)
EOF

  cat >"${OWASP_CRS_DIR}/${dir_name}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./configmap.yaml
EOF
done

echo "    Generated ${#COMPONENT_DIRS[@]} ConfigMap components"

# ─── Generate Secret for .data Files ─────────────────────────────────────────
shopt -s nullglob
DATA_FILES=("${CRS_DATA_DIR}"/*.data)
shopt -u nullglob

if [[ ${#DATA_FILES[@]} -gt 0 ]]; then
  echo "==> Generating CRS data Secret (${#DATA_FILES[@]} data files)..."
  cat >"${OWASP_CRS_DIR}/secret.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: crs-rule-data
  namespace: ${NAMESPACE}
type: coraza/data
stringData:
EOF
  for f in "${DATA_FILES[@]}"; do
    bn=$(basename "${f}")
    printf '  %s: |\n' "${bn}" >>"${OWASP_CRS_DIR}/secret.yaml"
    sed 's/^/    /' "${f}" >>"${OWASP_CRS_DIR}/secret.yaml"
  done
fi

# ─── owasp-crs/kustomization.yaml ────────────────────────────────────────────
echo "==> Writing owasp-crs/kustomization.yaml..."

ENABLED=()
DISABLED=()
for dir in $(printf '%s\n' "${COMPONENT_DIRS[@]}" | sort); do
  is_disabled=false
  for rule in "${DISABLED_RESPONSE_RULES[@]}"; do
    if [[ "${dir}" == "${rule}" ]]; then
      is_disabled=true
      break
    fi
  done
  if "${is_disabled}"; then
    DISABLED+=("${dir}")
  else
    ENABLED+=("${dir}")
  fi
done

{
  echo "apiVersion: kustomize.config.k8s.io/v1alpha1"
  echo "kind: Component"
  if [[ -f "${OWASP_CRS_DIR}/secret.yaml" ]]; then
    echo "resources:"
    echo "  - ./secret.yaml"
  fi
  echo "components:"
  for d in "${ENABLED[@]}"; do
    echo "  - ./${d}"
  done
  if [[ ${#DISABLED[@]} -gt 0 ]]; then
    echo "  # Response body inspection rules — not supported in Envoy WASM mode"
    for d in "${DISABLED[@]}"; do
      echo "  # - ./${d}"
    done
  fi
} >"${OWASP_CRS_DIR}/kustomization.yaml"

# ─── Update crs-setup/configmap.yaml ─────────────────────────────────────────
echo "==> Updating crs-setup ConfigMap for v${CRS_VERSION}..."
CRS_SETUP_VERSION=$(echo "${CRS_VERSION}" | tr -d '.')
mkdir -p "${CRS_SETUP_DIR}"

cat >"${CRS_SETUP_DIR}/configmap.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coraza-crs-setup
  namespace: ${NAMESPACE}
data:
  rules: |
    # -- OWASP CRS v${CRS_VERSION} Setup Configuration (from crs-setup.conf.example)

    # Anomaly Scoring mode (default)
    SecDefaultAction "phase:1,log,auditlog,pass"
    SecDefaultAction "phase:2,log,auditlog,pass"

    # Enable early blocking for faster enforcement
    SecAction \\
        "id:900120,\\
         phase:1,\\
         pass,\\
         t:none,\\
         nolog,\\
         tag:'OWASP_CRS',\\
         ver:'OWASP_CRS/${CRS_VERSION}',\\
         setvar:tx.early_blocking=1"

    # CRS setup version marker (required by CRS rules)
    SecAction \\
        "id:900990,\\
         phase:1,\\
         pass,\\
         t:none,\\
         nolog,\\
         tag:'OWASP_CRS',\\
         ver:'OWASP_CRS/${CRS_VERSION}',\\
         setvar:tx.crs_setup_version=${CRS_SETUP_VERSION}"
EOF

# ─── Format Generated Files ──────────────────────────────────────────────────
echo "==> Running prettier on generated YAML..."
if command -v prettier &>/dev/null; then
  prettier --write \
    "${OWASP_CRS_DIR}/**/*.yaml" \
    "${OWASP_CRS_DIR}/*.yaml" \
    "${CRS_SETUP_DIR}/configmap.yaml"
else
  echo "    WARN: prettier not found in PATH, skipping formatting" >&2
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==> Done! CRS rules regenerated."
echo "    Source:     ${SOURCE} (${REPO_URL})"
echo "    Version:    v${CRS_VERSION}"
echo "    Components: ${#ENABLED[@]} enabled, ${#DISABLED[@]} disabled (commented out)"
echo "    Output:     ${OWASP_CRS_DIR}"
