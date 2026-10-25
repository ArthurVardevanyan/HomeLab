#!/bin/bash
# ==============================================================================
# MicroShift BootC Entry Point Service Script
# ==============================================================================
# This script serves as the entrypoint for the MicroShift BootC container
# and handles:
# - Image SHA change detection (triggers graceful restart)
# - DNS validation (ensures cluster can reach external registries)
# - Graceful restart management
# - Kubeconfig exposure
# - Optional Cockpit installation
# ==============================================================================

set -euo pipefail

# ---- Configuration ----
CONTAINER_NAME="${CONTAINER_NAME:-microshift-okd}"
LVM_DISK="${LVM_DISK:-/var/lib/microshift-okd/lvmdisk.image}"
LVM_VOLSIZE="${LVM_VOLSIZE:-100G}"
VG_NAME="${VG_NAME:-myvg1}"
EXTRA_CONFIG="${EXTRA_CONFIG:-/var/lib/microshift-okd/custom_config.yaml}"
DOMAIN="${DOMAIN:-microshift.dc2.vardevanyan.com}"
API_SERVER_PORT="${API_SERVER_PORT:-6443}"
KUBECONFIG="${KUBECONFIG:-/var/lib/microshift/resources/kubeadmin/kubeconfig}"
LAST_IMAGE_FILE="${LAST_IMAGE_FILE:-/var/lib/microshift-okd/.last_image}"
COCKPIT="${COCKPIT:-0}"

# ---- Color codes ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- Helper Functions ----

check_image_change() {
  # Detect if the image SHA has changed since last run
  if [[ -f "${LAST_IMAGE_FILE}" ]] ; then
    local old_image
    old_image=$(cat "${LAST_IMAGE_FILE}")
    
    # Get the current image SHA (extracted from the container's image reference)
    local current_image
    current_image=$(podman inspect "${CONTAINER_NAME}" --format '{{.Image}}' 2>/dev/null || echo "")
    
    if [[ -n "${current_image}" ]] && [[ "${current_image}" != "${old_image}" ]] ; then
      log_warn "Image change detected!"
      log_warn "  Old: ${old_image}"
      log_warn "  New: ${current_image}"
      echo "${current_image}" > "${LAST_IMAGE_FILE}"
      return 0  # Image changed
    fi
  fi
  
  # Store current image SHA
  mkdir -p "$(dirname "${LAST_IMAGE_FILE}")"
  local current_image
  current_image=$(podman inspect "${CONTAINER_NAME}" --format '{{.Image}}' 2>/dev/null || echo "")
  if [[ -n "${current_image}" ]] ; then
    echo "${current_image}" > "${LAST_IMAGE_FILE}"
  fi
  
  return 1  # No change
}

validate_dns() {
  # Validate DNS resolution inside container
  log_info "Validating DNS resolution..."
  
  if ! podman exec "${CONTAINER_NAME}" getent hosts quay.io &>/dev/null; then
    log_error "DNS resolution for 'quay.io' failed inside the container."
    log_info "MicroShift pods will not be able to pull container images."
    echo ""
    log_info "This is commonly caused by VPN connections or custom DNS settings"
    log_info "on the host that are not available inside the container."
    log_info "Consider disconnecting from VPN or configuring DNS manually."
    echo ""
    return 1
  fi
  
  log_success "DNS validation passed."
  return 0
}

extract_kubeconfig() {
  # Extract kubeconfig from container to host
  local kubeconfig_local="${HOME}/.kube/config"
  
  log_info "Extracting kubeconfig..."
  
  mkdir -p "$(dirname "${kubeconfig_local}")"
  
  # Copy kubeconfig from container
  podman cp "${CONTAINER_NAME}:${KUBECONFIG}" "${kubeconfig_local}" 2>/dev/null
  
  # Fix permissions
  chmod 600 "${kubeconfig_local}"
  chown "${USER}:${USER}" "${kubeconfig_local}" 2>/dev/null || true
  
  log_success "Kubeconfig extracted to: ${kubeconfig_local}"
}

verify_health() {
  log_info "Verifying MicroShift health..."
  
  if kubectl get nodes &>/dev/null; then
    log_success "Cluster health verified."
  else
    log_warn "Could not verify cluster health (kubectl may not be configured yet)."
  fi
}

install_cockpit() {
  # Install and configure Cockpit (opt-in)
  if [[ "${COCKPIT}" -eq 1 ]] ; then
    log_info "Installing Cockpit..."
    
    # Install cockpit and dependencies
    dnf install -y cockpit pcp cockpit-podman cockpit-ws cockpit-bridge
    
    # Create cockpit config directory
    local cockpit_conf_dir="/etc/cockpit/conf.d"
    local machines_d="/etc/cockpit/machines.d"
    mkdir -p "${cockpit_conf_dir}" "${machines_d}"
    
    # Create 99-webui.json config
    if [[ ! -f "${machines_d}/99-webui.json" ]] ; then
      cat > "${machines_d}/99-webui.json" <<EOF
{
  "name": "MicroShift Cluster",
  "url": "https://${DOMAIN}:6443",
  "token": "",
  "image": "default",
  "os": "Red Hat Enterprise Linux",
  "color": "#333333",
  "icon": "system"
}
EOF
      log_success "Cockpit cluster config created: ${machines_d}/99-webui.json"
    fi
    
    # Start and enable cockpit
    systemctl enable --now cockpit.socket
    systemctl enable --now cockpit
    
    # Restart MicroShift to pick up cockpit config changes
    systemctl try-restart microshift.service 2>/dev/null || true
    
    log_success "Cockpit installed and configured."
  else
    log_info "Skipped Cockpit installation (set COCKPIT=1 to enable)"
  fi
}

show_instructions() {
  echo ""
  echo -e "${BLUE}========================================================================${NC}"
  echo -e "${BLUE}  MicroShift bootc deployment completed successfully!${NC}"
  echo -e "${BLUE}========================================================================${NC}"
  echo ""
  echo "CONTAINER:    ${CONTAINER_NAME}"
  echo "DOMAIN:       ${DOMAIN}"
  echo "LVM DISK:     ${LVM_DISK} (${LVM_VOLSIZE})"
  echo "VG NAME:      ${VG_NAME}"
  echo ""
  echo "To access the container:"
  echo "  sudo podman exec -it ${CONTAINER_NAME} /bin/bash -l"
  echo ""
  echo "To verify pods are running:"
  echo "  kubectl get pods -A"
  echo ""
  echo "To check cluster health:"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"
  echo ""
  echo "========================================================================"
}

# ---- Main Execution Flow ----

log_info "Starting MicroShift bootc entrypoint..."

# 1. Check for image changes and handle graceful restart
if check_image_change; then
  log_warn "Image changed - initiating graceful restart..."
  systemctl restart microshift.service
  log_success "Graceful restart completed."
fi

# 2. Start MicroShift service
log_info "Starting MicroShift service..."
systemctl start microshift.service

# 3. Wait for MicroShift to be ready
log_info "Waiting for MicroShift to start..."
kubeconfig="/var/lib/microshift/resources/kubeadmin/kubeconfig"
max_wait=300
waited=0

while [[ "${waited}" -lt "${max_wait}" ]] ; do
  if podman exec "${CONTAINER_NAME}" /bin/test -f "${kubeconfig}" &>/dev/null; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done

if [[ "${waited}" -ge "${max_wait}" ]] ; then
  log_error "Timed out waiting for MicroShift to start after ${max_wait}s"
  log_warn "Container still running. Check logs: podman logs ${CONTAINER_NAME} --tail=100"
  exit 1
fi

# 4. Validate DNS resolution
validate_dns

# 5. Extract kubeconfig
extract_kubeconfig

# 6. Verify health
verify_health

# 7. Install Cockpit (opt-in)
install_cockpit

# 8. Show instructions
show_instructions

exit 0
