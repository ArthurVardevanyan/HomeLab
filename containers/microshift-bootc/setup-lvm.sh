#!/bin/bash
# ==============================================================================
# Setup LVM for MicroShift BootC (Host-side provisioning)
# ==============================================================================
# This script runs on the host to:
# - Create LVM disk image file
# - Set up LVM volume group
# - Prepare for TopoLVM CSI
# ==============================================================================

set -euo pipefail

# ---- Configuration ----
LVM_DISK="${LVM_DISK:-/var/lib/microshift-okd/lvmdisk.image}"
LVM_VOLSIZE="${LVM_VOLSIZE:-100G}"
VG_NAME="${VG_NAME:-myvg1}"

log_info() { echo -e "[INFO] $1"; }
log_warn() { echo -e "[WARN] $1"; }
log_error() { echo -e "[ERROR] $1"; }

check_prerequisites() {
  log_info "Checking prerequisites..."

  # Check if running as root
  user_id="$(id -u)"
  if [[ $user_id -ne 0 ]] ; then
    log_error "This script must be run as root (use sudo)"
    exit 1
  fi

  # Check required tools
  local tools=("podman" "vgcreate" "losetup" "truncate" "lvcreate")
  for tool in "${tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "'${tool}' is not installed."
      exit 1
    fi
  done

  log_info "All prerequisites satisfied."
}

prepare_lvm_disk() {
  local lvm_disk="$1"
  local vg_name="$2"
  local volsize="$3"

  if [[ -f "${lvm_disk}" ]] ; then
    log_warn "LVM disk already exists: ${lvm_disk}"
    log_info "LVM disk will be reused (data preserved)."
    return 0
  fi

  log_info "Creating LVM disk: ${lvm_disk} (${volsize})..."

  # Create directory if needed
  mkdir -p "$(dirname "${lvm_disk}")"

  # Create disk image
  truncate --size="${volsize}" "${lvm_disk}"

  # Set up loop device
  local device_name
  device_name=$(losetup --find --show --nooverlap "${lvm_disk}")

  # Create volume group
  vgcreate -f -y "${vg_name}" "${device_name}"

  log_info "LVM disk created: ${lvm_disk} (${volsize}) at VG: ${vg_name}"
  log_info "Device: ${device_name}"
  log_info "Volume Group: ${vg_name}"
}

setup_lvm_service() {
  log_info "Setting up LVM service configuration..."

  # Create systemd drop-in for MicroShift service
  mkdir -p /etc/systemd/system/microshift.service.d

  cat > /etc/systemd/system/microshift.service.d/99-lvm-config.conf <<EOF
[Service]
ExecStartPre=/bin/bash -c 'vgs "${VG_NAME}" || vgcreate -f -y "${VG_NAME}" "\$(losetup --find --show --nooverlap "${LVM_DISK}")"'
EOF

  systemctl daemon-reload

  log_info "LVM service configuration set up."
}

show_instructions() {
  echo ""
  echo "========================================================================"
  echo "  LVM setup completed successfully!"
  echo "========================================================================"
  echo ""
  echo "LVM DISK:  ${LVM_DISK}"
  echo "LVM SIZE:  ${LVM_VOLSIZE}"
  echo "VG NAME:   ${VG_NAME}"
  echo ""
  echo "To verify LVM setup:"
  echo "  vgs"
  echo "  lvs"
  echo "  pvs"
  echo ""
  echo "To clean up:"
  echo "  lvremove -y ${VG_NAME}"
  echo "  losetup -D"
  echo "  rm -f ${LVM_DISK}"
  echo ""
  echo "========================================================================"
}

# ---- Main Execution ----

check_prerequisites
prepare_lvm_disk "${LVM_DISK}" "${VG_NAME}" "${LVM_VOLSIZE}"
setup_lvm_service
show_instructions

exit 0
