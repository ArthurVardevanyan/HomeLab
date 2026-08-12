#!/usr/bin/env bash
# kubernetes/tekton/create_manifest.sh
#
# Regenerates overlays/operator/operator.yaml and crds.yaml from upstream Tekton
# operator release merged with local customizations (checkov skips, namespace,
# securityContext, local-only CRDs).
#
# Usage:
#   ./create_manifest.sh [VERSION] [--report] [--debug]
#   ./create_manifest.sh 0.81.0          # specific version
#   ./create_manifest.sh                 # latest release from GitHub API
#   ./create_manifest.sh --report        # diff against current output (no write)
#   ./create_manifest.sh --debug 0.81.0  # keep temp files for inspection

set -o errexit -o nounset -o pipefail
shopt -s failglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPERATOR_YAML="${SCRIPT_DIR}/overlays/operator/operator.yaml"

# ── Argument parsing ───────────────────────────────────────────────
# Flags (--report, --debug) may appear anywhere; the first non-flag argument is
# the version. This keeps `./create_manifest.sh --report` from treating the
# flag as a version.
VERSION=""
REPORT_MODE=false
DEBUG_MODE=false
for arg in "$@"; do
  case "${arg}" in
    --report) REPORT_MODE=true ;;
    --debug) DEBUG_MODE=true ;;
    -*) echo "Unknown option: ${arg}" >&2; exit 1 ;;
    *)
      if [[ -z "${VERSION}" ]]; then
        VERSION="${arg}"
      else
        echo "Unexpected extra argument: ${arg}" >&2
        exit 1
      fi
      ;;
  esac
done

# ── Version resolution ──────────────────────────────────────────────
if [[ -z "${VERSION}" ]]; then
  # Fetch the latest release tag. `ltrimstr` is not supported by yq v4, so read
  # the raw tag (including the "v" prefix) and strip it via bash below.
  VERSION="$(curl -sL https://api.github.com/repos/tektoncd/operator/releases/latest \
    | yq -r '.tag_name' || true)"
  if [[ -z "${VERSION}" ]] || [[ "${VERSION}" = "null" ]]; then
    echo "ERROR: Failed to detect latest upstream release from GitHub API" >&2
    exit 1
  fi
  echo "Detected latest upstream version: ${VERSION}"
fi

# Normalize any leading "v" so both "0.81.0" and "v0.81.0" work.
VERSION="${VERSION#v}"
VERSION_TAG="v${VERSION}"
UPSTREAM_URL="https://github.com/tektoncd/operator/releases/download/v${VERSION}/openshift-release.yaml"

# ── Temporary workspace ─────────────────────────────────────────────
# --debug keeps a stable, inspectable temp dir (no auto-cleanup) and prints its
# path, mirroring the old create_manifest.debug.sh behavior. The default mode
# uses a throwaway dir that is cleaned up on exit.
if [[ "${DEBUG_MODE}" = true ]]; then
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tekton-manifest.XXXXXX")"
  echo "Debug mode: temp files kept in ${TEMP_DIR}"
else
  TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TEMP_DIR}"' EXIT
fi

SPLIT_DIR="${TEMP_DIR}/split"
mkdir -p "${SPLIT_DIR}/upstream"

if [[ "${REPORT_MODE}" = true ]]; then
  echo "Report mode: comparing new merged output against current operator.yaml + crds.yaml"
fi

# ── Download upstream ───────────────────────────────────────────────
echo "Downloading ${UPSTREAM_URL}..."
# -f fails on HTTP errors (404/503/...), which otherwise return an HTML error
# page (non-empty) that would pass the empty-file check below.
if ! curl -fsL "${UPSTREAM_URL}" -o "${TEMP_DIR}/upstream.yaml"; then
  echo "ERROR: Failed to download upstream release" >&2
  exit 1
fi

if [[ ! -s "${TEMP_DIR}/upstream.yaml" ]]; then
  echo "ERROR: Downloaded upstream release is empty" >&2
  exit 1
fi

# ── Split multi-doc YAML into individual files ──────────────────────
# Flushes a document whenever a `---` separator or EOF is reached and there is
# accumulated content. This is robust to an input file that does NOT begin with
# `---` (e.g. the previously-prettier'd operator.yaml), which used to cause the
# first two resources to be merged into a single split file and silently lose
# the first resource's local overrides.
split_yaml() {
  local input_file="$1"
  local output_dir="$2"
  local n=0
  local content=""

  flush() {
    if [[ -n "${content}" ]]; then
      printf '%s\n' "${content}" > "${output_dir}/doc_$(printf '%02d' "${n}").yaml"
      n=$((n + 1))
      content=""
    fi
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" = "---" ]]; then
      flush
    else
      content="${content}${line}"$'\n'
    fi
  done < "${input_file}"

  # Save final document (no trailing separator before EOF)
  flush
}

# Upstream release always starts with a `---`; rely on split_yaml's own
# robustness rather than a mandatory leading marker.
split_yaml "${TEMP_DIR}/upstream.yaml" "${SPLIT_DIR}/upstream"

UPSTREAM_COUNT="$(find "${SPLIT_DIR}/upstream" -maxdepth 1 -name '*.yaml' | wc -l)"
echo "Split upstream: ${UPSTREAM_COUNT} docs"

# ── Skip list ───────────────────────────────────────────────────────
# Upstream resources to drop entirely from the merged output.
#   Namespace|openshift-operators: the operator runs in a locally managed
#     namespace (base/namespace.yaml) so upstream's default OLM namespace is not
#     wanted. Other upstream CRDs are shipped verbatim.
SKIP="Namespace|openshift-operators"

# ── Version label fix ───────────────────────────────────────────────
# Set operator.tekton.dev/release and version labels to the target version.
fix_version_labels() {
  local input_file="$1"
  local output_file="$2"

  yq eval "
    .metadata.labels.\"operator.tekton.dev/release\" = \"${VERSION_TAG}\" |
    .metadata.labels.version = \"${VERSION_TAG}\"
  " "${input_file}" > "${output_file}"
}

# ── Customization transforms ────────────────────────────────────────
# Local policy is: the upstream release is the authoritative base; this script
# pins a small, explicit set of deltas on top via yq transform files. It does
# NOT merge stale full local copies back in, so upstream-owned content (RBAC
# .rules, ConfigMap .data, Service .spec, new rules/resources added in newer
# releases such as networkpolicies) always flows through verbatim.
# NOTE: yq's expression-from-file flag is `--from-file` (NOT `-f`, which means
# front-matter). These files live in TEMP_DIR and are consumed with
# `yq eval --from-file`.

# Standard (non-Deployment) resources: namespace relabel, subject namespace,
# instance label, and the targeted annotation/port/named-port patches.
cat > "${TEMP_DIR}/transform-standard.yq" <<'YQTF'
with(select(.metadata.namespace == "openshift-operators");
  .metadata.namespace = "openshift-pipelines-operator"
) |
with(select(.kind == "ClusterRoleBinding");
  .subjects[] |= (with(select(.namespace == "openshift-operators"); .namespace = "openshift-pipelines-operator"))
) |
with(select(.metadata.labels."app.kubernetes.io/instance" == "default");
  .metadata.labels."app.kubernetes.io/instance" = "tekton"
) |
with(select(.kind == "ClusterRole" and .metadata.name == "tekton-operator");
  .metadata.annotations."checkov.io/skip1" = "CKV_K8S_155=Required" |
  .metadata.annotations."checkov.io/skip2" = "CKV_K8S_158=Required" |
  .metadata.annotations."gitops-ci.k8s.io/exempt-rbac-wildcards" = "resources"
) |
with(select(.kind == "ServiceMonitor");
  .spec.namespaceSelector.matchNames = ["openshift-pipelines-operator"]
) |
with(select(.kind == "Service" and (.metadata.name == "tekton-operator" or .metadata.name == "tekton-operator-webhook"));
  .spec.ports[] |= (.targetPort = .name)
)
YQTF

# Deployment resources: upstream base for image/args/env (so version bumps are
# never masked); local securityContext, resources, imagePullPolicy, resizePolicy,
# pod-level scheduling flags, checkov skip annotations, and the required-scc pod
# annotation are layered on top. One upstream container arg (tektonhub) that
# upstream removed is upstream-owned and therefore not re-added.
cat > "${TEMP_DIR}/transform-deployment.yq" <<'YQTF'
with(select(.metadata.namespace == "openshift-operators");
  .metadata.namespace = "openshift-pipelines-operator"
) |
.metadata.annotations."checkov.io/skip1" = "CKV_K8S_40=OpenShift Injects Random UID" |
.metadata.annotations."checkov.io/skip2" = "CKV_K8S_23=https://github.com/tektoncd/operator/issues/1772" |
.metadata.annotations."checkov.io/skip3" = "CKV_K8S_8=Not Provided" |
.metadata.annotations."checkov.io/skip4" = "CKV_K8S_9=Not Provided" |
.metadata.annotations."checkov.io/skip6" = "CKV_K8S_38=Operator Needs API Access" |
.spec.template.metadata.annotations."openshift.io/required-scc" = "restricted-v2" |
.spec.template.spec.automountServiceAccountToken = true |
.spec.template.spec.dnsPolicy = "ClusterFirst" |
.spec.template.spec.restartPolicy = "Always" |
.spec.template.spec.schedulerName = "default-scheduler" |
.spec.template.spec.enableServiceLinks = false |
.spec.template.spec.securityContext = {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}} |
.spec.template.spec.containers[] |= (
  .securityContext = {"runAsNonRoot": true, "allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "privileged": false, "readOnlyRootFilesystem": true, "seccompProfile": {"type": "RuntimeDefault"}} |
  .imagePullPolicy = "IfNotPresent" |
  .resizePolicy = [{"resourceName": "cpu", "restartPolicy": "NotRequired"}, {"resourceName": "memory", "restartPolicy": "NotRequired"}]
) |
with(select(.metadata.name == "openshift-pipelines-operator");
  .spec.template.spec.containers[] |= .resources = {"limits": {"cpu": "60m", "memory": "192Mi"}, "requests": {"cpu": "10m", "memory": "96Mi"}} |
  (.spec.template.spec.containers[] | select(.name == "openshift-pipelines-operator-lifecycle") | .ports) = [{"containerPort": 9090, "name": "http-metrics"}]
) |
with(select(.metadata.name == "tekton-operator-webhook");
  .spec.template.spec.containers[] |= .resources = {"limits": {"cpu": "60m", "memory": "64Mi"}, "requests": {"cpu": "10m", "memory": "32Mi"}}
)
YQTF

# ── Merge and output ────────────────────────────────────────────────
OUTPUT_FILE="${TEMP_DIR}/output.yaml"
: > "${OUTPUT_FILE}"

DOC_COUNT=0
SKIPPED_COUNT=0
declare -a ACTUALLY_SKIPPED=()

echo "---" >> "${OUTPUT_FILE}"

for f in "${SPLIT_DIR}/upstream"/doc_*.yaml; do
  kind="$(yq -r '.kind' "${f}")"
  name="$(yq -r '.metadata.name' "${f}")"
  RID="${kind}|${name}"

  # Check skip list
  if echo "${SKIP}" | grep -qx "${RID}"; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    ACTUALLY_SKIPPED+=("${RID}")
    continue
  fi

  # Start from upstream and layer the pinned customizations on top.
  if [[ "${kind}" = "Deployment" ]]; then
    TF_FILE="${TEMP_DIR}/transform-deployment.yq"
  else
    TF_FILE="${TEMP_DIR}/transform-standard.yq"
  fi

  # shellcheck disable=SC2016
  yq eval --from-file "${TF_FILE}" "${f}" > "${TEMP_DIR}/transformed.yaml"
  fix_version_labels "${TEMP_DIR}/transformed.yaml" "${TEMP_DIR}/transformed.labeled"
  cat "${TEMP_DIR}/transformed.labeled" >> "${OUTPUT_FILE}"

  echo "---" >> "${OUTPUT_FILE}"
  DOC_COUNT=$((DOC_COUNT + 1))
done

# NOTE: there are intentionally no "local-only" resources. The upstream release
# is authoritative: if a resource is not in the release manifest (e.g. RBAC that
# upstream dropped in a newer version, like tekton-multicluster-proxy-aae-role),
# it is not carried forward. Any genuinely local resource belongs in its own
# overlay file referenced by kustomization.yaml, not baked into operator.yaml.
LocalOnly_COUNT=0

# ── Strip trailing document separator ───────────────────────────────
# The loop appends --- after every document, leaving one at the end.
# Use perl to remove only the final --- (and trailing blank lines) at EOF.
perl -0pe 's/\n+---\s*\z//' "${OUTPUT_FILE}" > "${TEMP_DIR}/output_clean.yaml"

# ── Split output into CRDs and non-CRDs ─────────────────────────────
# CRDs go into a dedicated file; everything else stays in operator.yaml.
CRDS_FILE="${TEMP_DIR}/crds.yaml"
OPERATOR_FILE="${TEMP_DIR}/operator.yaml"

# CRD documents
yq eval-all 'select(.kind == "CustomResourceDefinition" and .kind != null)' \
  "${TEMP_DIR}/output_clean.yaml" > "${CRDS_FILE}" 2>/dev/null
if ! grep -q '^kind: CustomResourceDefinition' "${CRDS_FILE}"; then
  echo "---" > "${CRDS_FILE}"
fi

# Non-CRD documents
yq eval-all 'select(.kind != "CustomResourceDefinition" and .kind != null and .kind != "")' \
  "${TEMP_DIR}/output_clean.yaml" > "${OPERATOR_FILE}" 2>/dev/null
if ! grep -q '^kind:' "${OPERATOR_FILE}"; then
  echo "---" > "${OPERATOR_FILE}"
fi

# Count CRDs and non-CRDs by counting kind headers. grep -c returns non-zero
# (and prints "0") on no matches, which under `set -o pipefail` would not trip
# the `|| true`, but a trailing newline plus "0" is safe to collapse. Guard
# against an empty/garbage stream with awk so the count is always a clean int.
CRD_COUNT="$(grep -c '^kind: CustomResourceDefinition' "${CRDS_FILE}" 2>/dev/null | awk 'END{print (NR?$0:0)}' || true)"
OPERATOR_COUNT="$(grep -c '^kind:' "${OPERATOR_FILE}" 2>/dev/null | awk 'END{print (NR?$0:0)}' || true)"

# ── Report mode: compare old vs new and print report ────────────────
if [[ "${REPORT_MODE}" = true ]]; then
  # Save OLD operator.yaml baseline before splitting
  cp "${OPERATOR_YAML}" "${TEMP_DIR}/old_operator.yaml"

  # If OLD crds.yaml exists (from a previous split), save it too
  OLD_CRDS_FILE=""
  if [[ -f "${SCRIPT_DIR}/overlays/operator/crds.yaml" ]]; then
    cp "${SCRIPT_DIR}/overlays/operator/crds.yaml" "${TEMP_DIR}/old_crds.yaml"
    OLD_CRDS_FILE="${TEMP_DIR}/old_crds.yaml"
  fi

  # Combine old operator.yaml + old crds.yaml into one file to represent
  # the full OLD baseline before splitting.  This ensures the OLD index
  # and NEW index both contain the same resource types (no false "NEW" /
  # "REMOVED" entries caused by the split).
  OLD_MERGED="${TEMP_DIR}/old_merged.yaml"
  { echo "---"; cat "${TEMP_DIR}/old_operator.yaml"; } > "${OLD_MERGED}"
  if [[ -n "${OLD_CRDS_FILE}" ]] && [[ -s "${OLD_CRDS_FILE}" ]]; then
    echo "---" >> "${OLD_MERGED}"
    cat "${OLD_CRDS_FILE}" >> "${OLD_MERGED}"
  fi

  # Split OLD merged baseline
  OLD_SPLIT="${TEMP_DIR}/old_split"
  mkdir -p "${OLD_SPLIT}"
  { echo "---"; cat "${OLD_MERGED}"; } | split_yaml /dev/stdin "${OLD_SPLIT}"

  # Split NEW merged output into a temp dir for comparison
  NEW_SPLIT_DIR="${TEMP_DIR}/new_split"
  mkdir -p "${NEW_SPLIT_DIR}"
  { echo "---"; cat "${TEMP_DIR}/output_clean.yaml"; } | split_yaml /dev/stdin "${NEW_SPLIT_DIR}"

  # Build OLD index from combined baseline
  declare -A OLD_INDEX
  for f in "${OLD_SPLIT}"/doc_*.yaml; do
    kind="$(yq -r '.kind' "${f}")"
    name="$(yq -r '.metadata.name' "${f}")"
    if [[ -n "${kind}" ]] && [[ -n "${name}" ]] && [[ "${name}" != "null" ]]; then
      OLD_INDEX["${kind}|${name}"]="$(basename "${f}")"
    fi
  done

  # Build NEW index from merged output (before split)
  declare -A NEW_INDEX
  for f in "${NEW_SPLIT_DIR}"/doc_*.yaml; do
    kind="$(yq -r '.kind' "${f}")"
    name="$(yq -r '.metadata.name' "${f}")"
    if [[ -n "${kind}" ]] && [[ -n "${name}" ]] && [[ "${name}" != "null" ]]; then
      NEW_INDEX["${kind}|${name}"]="$(basename "${f}")"
    fi
  done

  # ── Field-level diff helper ───────────────────────────────────────
  # For CRDs: strips spec.versions.*.schema.openAPIV3Schema (auto-generated, too deep)
  # then flattens to sorted path-value pairs for semantic comparison.
  # Skips version-label paths and limits output to first N diffs.
  MAX_DIFFS=15
  MAX_DEPTH=3

  flatten_yaml() {
    local file="$1"
    local kind="$2"
    local yaml_content
    local depth_filter=""
    if [[ "${kind}" = "CustomResourceDefinition" ]]; then
      # CRDs embed the full OpenAPI v3 schema; strip it (auto-generated,
      # not worth diffing) and cap remaining depth to avoid noise from any
      # other deeply nested schema fields.
      yaml_content="$(yq eval 'del(.spec.versions[].schema.openAPIV3Schema)' "${file}" 2>/dev/null)"
      depth_filter="select(\$depth <= ${MAX_DEPTH}) | "
    else
      # Other kinds (Deployment, ...): no depth cap, since the fields that
      # matter most for a version bump (container image/args/env) live well
      # below depth 3 (spec.template.spec.containers.N.image = depth 6).
      yaml_content="$(cat "${file}")"
    fi
    echo "${yaml_content}" | yq eval -r \
      "[.. | select(tag != \"!!map\" and tag != \"!!seq\") | \
        (path | length) as \$depth | \
        ${depth_filter}\
        select(\$depth > 0) | \
        (path | join(\".\")) as \$p | \
        select(\$p | test(\"^metadata\\.labels\\.(version|operator\\.tekton\\.dev/release)\") | not) | \
        \$p + \"@@TAB@@\" + (. | tostring)] | sort | .[]" \
      2>/dev/null | sed 's/@@TAB@@/\t/g'
  }

  diff_resources() {
    local old_file="$1"
    local new_file="$2"
    local kind
    local old_flat
    local new_flat
    kind="$(yq -r '.kind' "${old_file}" 2>/dev/null)"
    old_flat="$(flatten_yaml "${old_file}" "${kind}")"
    new_flat="$(flatten_yaml "${new_file}" "${kind}")"

    local old_paths
    local new_paths
    old_paths="$(echo "${old_flat}" | cut -f1 | sort)"
    new_paths="$(echo "${new_flat}" | cut -f1 | sort)"

    # Removed paths (in old, not in new)
    local removed_paths
    removed_paths="$(comm -23 <(echo "${old_paths}") <(echo "${new_paths}"))"

    # Added paths (in new, not in old)
    local added_paths
    added_paths="$(comm -13 <(echo "${old_paths}") <(echo "${new_paths}"))"

    # Common paths with changed values
    local common_paths
    common_paths="$(comm -12 <(echo "${old_paths}") <(echo "${new_paths}"))"
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      local old_val
      local new_val
      old_val="$(echo "${old_flat}" | grep -F "${path}" | head -1 | cut -f2-)"
      new_val="$(echo "${new_flat}" | grep -F "${path}" | head -1 | cut -f2-)"
      if [[ "${old_val}" != "${new_val}" ]]; then
        echo "  → ${path}: ${old_val} → ${new_val}"
      fi
    done <<< "${common_paths}"

    # Removed fields
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      local val
      val="$(echo "${old_flat}" | grep -F "${path}" | head -1 | cut -f2-)"
      echo "  - ${path}: ${val}"
    done <<< "${removed_paths}"

    # Added fields (limited)
    local added_count=0
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      [[ "${added_count}" -ge "${MAX_DIFFS}" ]] && break
      local val
      val="$(echo "${new_flat}" | grep -F "${path}" | head -1 | cut -f2-)"
      echo "  + ${path}: ${val}"
      added_count=$((added_count + 1))
    done <<< "${added_paths}"

    local removed_count
    local total_added
    removed_count="$(echo "${removed_paths}" | grep -c '.' 2>/dev/null || true)"
    total_added="$(echo "${added_paths}" | grep -c '.' 2>/dev/null || true)"
    if [[ "${added_count}" -lt "${total_added}" ]] && [[ "${total_added}" -gt "${MAX_DIFFS}" ]]; then
      echo "  ... and $((total_added - MAX_DIFFS)) more added fields"
    fi
    if [[ "${removed_count}" -gt 0 ]]; then
      echo "  ... and ${removed_count} removed fields"
    fi
  }

  # ── Compare indices ───────────────────────────────────────────────
  NEW_COUNT=0
  REMOVED_COUNT=0
  CHANGED_COUNT=0
  VERSION_LABEL_CHANGES=0

  # Resources in NEW but not in OLD
  declare -a NEW_RESOURCES=()
  for rid in "${!NEW_INDEX[@]}"; do
    if [[ -z "${OLD_INDEX[${rid}]+x}" ]]; then
      NEW_RESOURCES+=("${rid}")
      NEW_COUNT=$((NEW_COUNT + 1))
    fi
  done

  # Resources in OLD but not in NEW
  declare -a REMOVED_RESOURCES=()
  for rid in "${!OLD_INDEX[@]}"; do
    if [[ -z "${NEW_INDEX[${rid}]+x}" ]]; then
      REMOVED_RESOURCES+=("${rid}")
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
  done

  # Resources in both but with differences
  declare -a CHANGED_RESOURCES=()
  declare -A CHANGED_DIFFS=()
  for rid in "${!NEW_INDEX[@]}"; do
    if [[ -n "${OLD_INDEX[${rid}]+x}" ]]; then
      old_file="${OLD_SPLIT}/${OLD_INDEX[${rid}]}"
      new_file="${NEW_SPLIT_DIR}/${NEW_INDEX[${rid}]}"
      diff_output="$(diff_resources "${old_file}" "${new_file}")"
      if [[ -n "${diff_output}" ]]; then
        # Check if the only difference is version labels
        # Count lines in diff that are NOT version label changes
        non_version_diffs="$(echo "${diff_output}" | grep -E '^[\+\-]' | grep -vcE 'version|operator\.tekton\.dev/release' 2>/dev/null || true)"
        if [[ "${non_version_diffs}" -gt 0 ]]; then
          CHANGED_RESOURCES+=("${rid}")
          CHANGED_DIFFS["${rid}"]="${diff_output}"
          CHANGED_COUNT=$((CHANGED_COUNT + 1))
        else
          # Only version labels differ — count them
          version_diffs="$(echo "${diff_output}" | grep -E '^[\+\-]' | grep -cE 'version|operator\.tekton\.dev/release' 2>/dev/null || true)"
          VERSION_LABEL_CHANGES=$((VERSION_LABEL_CHANGES + version_diffs))
        fi
      fi
    fi
  done

  # ── Print report ──────────────────────────────────────────────────
  echo ""
  echo "=== DIFF REPORT ==="
  echo "Version: v${VERSION} (upstream release)"
  echo "File: ${OPERATOR_YAML}"
  echo ""

  # Skipped resources (explicit listing)
  echo "SKIPPED (${SKIPPED_COUNT}):"
  if [[ ${#ACTUALLY_SKIPPED[@]} -gt 0 ]]; then
    printf '%s\n' "${ACTUALLY_SKIPPED[@]}" | sort | sed 's/^/  - /'
  else
    echo "  (none)"
  fi
  echo ""

  # CRD-specific changes
  echo "CRD Changes:"
  CRD_NEW=0
  CRD_REMOVED=0
  for rid in "${!NEW_INDEX[@]}"; do
    if [[ "${rid}" == CustomResourceDefinition* ]]; then
      if [[ -z "${OLD_INDEX[${rid}]+x}" ]]; then
        echo "  ADDED:"
        echo "    - ${rid}"
        CRD_NEW=$((CRD_NEW + 1))
      fi
    fi
  done
  for rid in "${!OLD_INDEX[@]}"; do
    if [[ "${rid}" == CustomResourceDefinition* ]]; then
      if [[ -z "${NEW_INDEX[${rid}]+x}" ]]; then
        echo "  REMOVED:"
        echo "    - ${rid}"
        CRD_REMOVED=$((CRD_REMOVED + 1))
      fi
    fi
  done
  if [[ "${CRD_NEW}" -eq 0 ]] && [[ "${CRD_REMOVED}" -eq 0 ]]; then
    echo "  (none)"
  fi
  echo ""

  # NEW
  echo "NEW: (${NEW_COUNT})"
  if [[ ${#NEW_RESOURCES[@]} -gt 0 ]]; then
    printf '%s\n' "${NEW_RESOURCES[@]}" | sort | sed 's/^/  /'
  fi
  echo ""

  # CHANGED
  echo "CHANGED: (${CHANGED_COUNT})"
  if [[ ${#CHANGED_RESOURCES[@]} -gt 0 ]]; then
    printf '%s\n' "${CHANGED_RESOURCES[@]}" | sort | while read -r rid; do
      echo "  ${rid}"
      echo "    ${CHANGED_DIFFS[${rid}]//$'\n'/$'\n'    }"
      echo ""
    done
  fi
  echo ""

  # REMOVED
  echo "REMOVED: (${REMOVED_COUNT})"
  if [[ ${#REMOVED_RESOURCES[@]} -gt 0 ]]; then
    printf '%s\n' "${REMOVED_RESOURCES[@]}" | sort | sed 's/^/  /'
  fi
  echo ""

  # SUMMARY. DOC_COUNT is the number of resources in the merged output, which is
  # exactly the upstream-derived resources (merged/kept) plus local-only ones.
  # Skipped upstream resources are excluded from DOC_COUNT entirely, so report
  # them as a separate informational figure rather than subtracting them.
  Merged_COUNT=$((DOC_COUNT - LocalOnly_COUNT))
  echo "SUMMARY"
  echo "  Total in merged output: ${DOC_COUNT} (${Merged_COUNT} merged + ${LocalOnly_COUNT} local-only, ${SKIPPED_COUNT} skipped)"
  echo "  CRDs: ${CRD_COUNT} | Other resources: ${OPERATOR_COUNT}"
  echo "  NEW: ${NEW_COUNT} | CHANGED: ${CHANGED_COUNT} | REMOVED: ${REMOVED_COUNT}"
  echo "  Version label changes: ${VERSION_LABEL_CHANGES} (excluded from diff)"
  echo ""

  if [[ "${NEW_COUNT}" -eq 0 ]] && [[ "${CHANGED_COUNT}" -eq 0 ]] && [[ "${REMOVED_COUNT}" -eq 0 ]]; then
    echo "No differences detected."
  else
    echo "To accept changes, run: ./create_manifest.sh ${VERSION}"
  fi

  exit 0
fi

# ── Copy output ─────────────────────────────────────────────────────
cp "${CRDS_FILE}" "${SCRIPT_DIR}/overlays/operator/crds.yaml"
cp "${OPERATOR_FILE}" "${OPERATOR_YAML}"

# Local policy: keep the IMAGE_ADDONS_OC env var disabled even though newer
# upstream releases ship it active. The Deployment merge forces .env back to
# upstream, so this active entry is re-added here and commented out (matching
# the commented form kept in older checked-in manifests). The regex matches
# only the active (uncommented) form, so re-running is idempotent.
# shellcheck disable=SC2016
perl -0pi -e 's/^([ \t]*)- name: IMAGE_ADDONS_OC\n([ \t]*)value: image-registry\.openshift-image-registry\.svc:5000\/openshift\/cli:latest/${1}# - name: IMAGE_ADDONS_OC\n${2}# value: image-registry.openshift-image-registry.svc:5000\/openshift\/cli:latest/m' "${OPERATOR_YAML}"

# Local policy: restore the rationale comment above the rbac-wildcards exemption
# on the tekton-operator ClusterRole. yq sets the annotation value but cannot
# emit the explanatory comment, so it is re-inserted here (idempotent: it only
# adds the block when it is not already present immediately above the key).
# shellcheck disable=SC2016
perl -0pi -e 's/(?<!\n#)(^([ \t]*)gitops-ci\.k8s\.io\/exempt-rbac-wildcards: )/${2}# The meta-operator manages arbitrary Tekton CRD kinds (TektonConfig,\n${2}# TektonAddon, TektonTrigger, ...) it can'"'"'t enumerate in advance, so\n${2}# `resources: ["*"]` is required within its own tekton.dev\/operator.tekton.dev\/\n${2}# dashboard.tekton.dev API groups - matches the checkov.io\/skip1-2 rationale\n${2}# above. NOTE: this annotation is not yet honored by the currently-released\n${2}# k8s-gitops-ci (named-ports\/podspec-defaults\/rbac-wildcards checks don'"'"'t\n${2}# populate Finding.Value\/Annotations yet - see ArthurVardevanyan\/k8s-gitops-ci\n${2}# follow-up); kubernetes\/tekton\/test.sh carries the equivalent EXEMPTIONS\n${2}# selector as the functional bridge until that ships, and can be dropped once\n${2}# this annotation alone is honored.\n${1}/m' "${OPERATOR_YAML}"

npx prettier --write "${SCRIPT_DIR}/overlays/operator/crds.yaml"
npx prettier --write "${OPERATOR_YAML}"
echo "Generated ${OPERATOR_YAML} + crds.yaml (${CRD_COUNT} CRDs, ${OPERATOR_COUNT} other resources, ${SKIPPED_COUNT} skipped)"
