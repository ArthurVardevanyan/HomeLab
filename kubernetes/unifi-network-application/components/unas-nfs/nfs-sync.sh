#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SSH_USER="$(cat /tmp/.ssh/username)"
SSH_PASS="$(cat /tmp/.ssh/password)"
SSH_HOST="unas.arthurvardevanyan.com"
REMOTE_EXPORTS_DIR="/etc/exports.d"

NEED_RESTART=false
HEALTH_ISSUES_FOUND=false

# ---- Phase 1: Sync exports files ----
for export_file in /tmp/exports/shared-*.exports; do
  filename="$(basename "${export_file}")"
  checksum_local="$(sha256sum "${export_file}" | awk '{print $1}')"
  checksum_remote="$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "if [[ -f '${REMOTE_EXPORTS_DIR}/${filename}' ]]; then sha256sum '${REMOTE_EXPORTS_DIR}/${filename}' | awk '{print \$1}'; else echo 'MISSING'; fi" 2>/dev/null || echo 'ERROR')"

  if [[ "${checksum_local}" != "${checksum_remote}" ]]; then
    echo "[${filename}] checksums differ (${checksum_remote} -> ${checksum_local}), syncing..."
    sshpass -p "${SSH_PASS}" scp "${export_file}" "${SSH_USER}@${SSH_HOST}:${REMOTE_EXPORTS_DIR}/${filename}"
    NEED_RESTART=true
  else
    echo "[${filename}] already in sync"
  fi
done

if ${NEED_RESTART}; then
  echo "Restarting nfs-server..."
  sshpass -p "${SSH_PASS}" ssh "${SSH_USER}@${SSH_HOST}" "sudo systemctl restart nfs-server"
  sleep 5
  sshpass -p "${SSH_PASS}" ssh "${SSH_USER}@${SSH_HOST}" "sudo systemctl status nfs-server"
fi

# ---- Phase 2: Check pod health for storage issues ----
# Minio storage error patterns
MINIO_PATTERNS="offline|unable to write|no online disks|file access denied|drive may be faulty|Unable to write to the backend"
# NFS/io error patterns
NFS_PATTERNS="IO error|stale file handle|nfs|mount error|input output error"
ALL_PATTERNS="${MINIO_PATTERNS}|${NFS_PATTERNS}"

check_pod_health() {
  local ns="$1"
  local selector="$2"
  local pod_names
  pod_names="$(kubectl get pods -n "${ns}" -l "${selector}" -o name --field-selector=status.phase=Running 2>/dev/null || true)"
  if [[ -n "${pod_names}" ]]; then
    while IFS= read -r pod; do
      if [[ -n "${pod}" ]]; then
        pod_name="${pod#pod/}"
        logs="$(kubectl logs "${pod}" -n "${ns}" --tail=500 --all-containers 2>/dev/null || true)"
        if echo "${logs}" | grep -iqE "${ALL_PATTERNS}"; then
          echo "[${ns}/${pod_name}] storage issues detected"
          return 0
        fi
      fi
    done <<< "${pod_names}"
  fi
  return 1
}

for ns_info in "minio-unas:app=minio-ssd" "minio-unas:app=minio" "immich:app.kubernetes.io/name=server,app.kubernetes.io/instance=immich"; do
  IFS=':' read -r ns selector <<< "${ns_info}"
  # shellcheck disable=SC2310
  if check_pod_health "${ns}" "${selector}"; then
    HEALTH_ISSUES_FOUND=true
  fi
done

# ---- Phase 3: Rolling restart if needed ----
if ${NEED_RESTART} || ${HEALTH_ISSUES_FOUND}; then
  echo "Triggering rolling restarts..."
  kubectl -n minio-unas rollout restart deployment minio-ssd
  kubectl -n minio-unas rollout restart deployment minio
  kubectl -n immich rollout restart deployment immich-server
fi

echo "NFS sync check complete"
