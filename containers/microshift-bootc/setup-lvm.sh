#!/bin/bash
# ==============================================================================
# Provision the TopoLVM backing volume group for MicroShift BootC
# ==============================================================================
# Runs at every boot from microshift-lvm.service (before microshift.service).
# Idempotent and non-destructive:
#   - sparse image file is created only if it does not exist
#   - loop device is attached (or reused if already attached)
#   - the VG is created ONLY when the device carries no signature at all;
#     an existing VG is just activated, never reformatted
# Can also be run by hand as root.
# ==============================================================================

set -euo pipefail

LVM_DISK="${LVM_DISK:-/var/lib/microshift-okd/lvmdisk.image}"
LVM_VOLSIZE="${LVM_VOLSIZE:-75G}"
VG_NAME="${VG_NAME:-myvg1}"

log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

uid="$(id -u)"
if [[ "${uid}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for tool in truncate losetup vgcreate vgchange vgs blkid lvmdevices; do
  if ! command -v "${tool}" &>/dev/null; then
    log_error "'${tool}' is not installed."
    exit 1
  fi
done

mkdir -p "$(dirname "${LVM_DISK}")"

# 1. Backing file (sparse; only allocates space as TopoLVM uses it)
if [[ ! -f "${LVM_DISK}" ]]; then
  log_info "Creating sparse backing file ${LVM_DISK} (${LVM_VOLSIZE})"
  truncate --size="${LVM_VOLSIZE}" "${LVM_DISK}"
else
  log_info "Reusing backing file ${LVM_DISK}"
fi

# 2. Loop device (reuse an existing attachment)
loop_dev="$(losetup -j "${LVM_DISK}" | head -n1 | cut -d: -f1)"
if [[ -z "${loop_dev}" ]]; then
  loop_dev="$(losetup --find --show --nooverlap "${LVM_DISK}")"
  log_info "Attached ${LVM_DISK} to ${loop_dev}"
else
  log_info "${LVM_DISK} already attached to ${loop_dev}"
fi

# 3. Volume group
if ! vgs "${VG_NAME}" &>/dev/null; then
  # LVM ignores devices that are not in /etc/lvm/devices/system.devices.
  lvmdevices --adddev "${loop_dev}" &>/dev/null || true
fi

if vgs "${VG_NAME}" &>/dev/null; then
  log_info "Volume group ${VG_NAME} exists, activating"
  vgchange -ay "${VG_NAME}"
elif blkid -p "${loop_dev}" &>/dev/null; then
  # The device has a signature but no usable VG: refuse to destroy it.
  log_error "${loop_dev} carries an existing signature but VG ${VG_NAME} was not found; refusing to reformat"
  blkid -p "${loop_dev}" >&2 || true
  exit 1
else
  log_info "Creating volume group ${VG_NAME} on ${loop_dev}"
  vgcreate -y "${VG_NAME}" "${loop_dev}"
fi

vgs "${VG_NAME}"
