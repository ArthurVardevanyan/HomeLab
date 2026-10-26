#!/usr/bin/env bash
# Build out-of-tree UFS host controller modules for the CentOS Stream 10 kernel
# installed in this image (the stock kernel ships with CONFIG_SCSI_UFSHCD unset).
#
# Needed for MinisForum S100 (Intel Alder Lake-N UFS, PCI 8086:54ff).
#
# The modules are built against the distro's own kernel-devel package (exact
# .config, Module.symvers and generated headers), NOT a regenerated config.
# A regenerated config (olddefconfig without pahole) silently dropped
# CONFIG_DEBUG_INFO_BTF / SCHED_CLASS_EXT, which changed sizeof(struct module)
# and made the kernel reject the modules at boot:
#   "module ufshcd_core: .gnu.linkonce.this_module section size must match
#    the kernel's struct module size at run time"
#
# Output: /out/ufs/{ufshcd-core,ufshcd-pci,ufshcd-pltfrm}.ko and /out/kver
# Modules are unsigned, so Secure Boot must be disabled on the target.
#
# Env:
#   WITH_UFS     1 builds the modules, 0 skips (empty /out); anything else is an error
set -o errexit -o nounset -o pipefail

OUT=/out
mkdir -p "${OUT}/ufs"

case "${WITH_UFS:-}" in
  1) ;;
  0)
    echo "WITH_UFS=0, skipping UFS module build"
    exit 0
    ;;
  *)
    echo "ERROR: WITH_UFS must be 0 or 1, got '${WITH_UFS:-}'" >&2
    exit 1
    ;;
esac

KVER=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if [ "$(echo "${KVER}" | wc -l)" -ne 1 ]; then
  echo "ERROR: expected exactly one kernel in /usr/lib/modules, found:" >&2
  echo "${KVER}" >&2
  exit 1
fi
SRC_VER=${KVER%.x86_64}
SRC_VER=${SRC_VER%.aarch64}
ARCH=$(uname -m)
echo "Building UFS modules for kernel ${KVER}"

# kernel-devel must match the running kernel exactly. Do not fall back to a
# different kernel's headers or a regenerated config: fail with a clear message.
if ! dnf -y install gcc make elfutils-libelf-devel openssl-devel bc flex bison \
  perl xz tar cpio rpm-build "kernel-devel-${KVER}"; then
  echo "ERROR: kernel-devel-${KVER} is not available in the enabled repos." >&2
  echo "The mirror may lag behind the base image's kernel. Retry once it" >&2
  echo "catches up, or build against an older base image." >&2
  exit 1
fi
KDEVEL="/usr/src/kernels/${KVER}"
[ -f "${KDEVEL}/.config" ] || {
  echo "ERROR: ${KDEVEL}/.config not found after installing kernel-devel" >&2
  exit 1
}

WORK=$(mktemp -d)
cd "${WORK}"

SRPM="kernel-${SRC_VER}.src.rpm"
for base in \
  "https://mirror.stream.centos.org/10-stream/BaseOS/source/tree/Packages" \
  "https://composes.stream.centos.org/stream-10/production/latest-CentOS-Stream/compose/BaseOS/source/tree/Packages"; do
  if curl -fsSL --retry 3 -o "${SRPM}" "${base}/${SRPM}"; then
    break
  fi
  rm -f "${SRPM}"
done
[ -s "${SRPM}" ] || {
  echo "ERROR: could not download ${SRPM}" >&2
  exit 1
}

# Only the UFS driver sources are needed, not the whole tree.
rpm2cpio "${SRPM}" | cpio -idm --quiet "linux-*.tar.xz"
tar -xf linux-*.tar.xz --wildcards '*/drivers/ufs' '*/include/ufs'
# Directories only: the tarball ("linux-*.tar.xz") sits next to the source dir.
SRC=$(find "${WORK}" -mindepth 1 -maxdepth 1 -type d -name 'linux-*')
[ "$(echo "${SRC}" | wc -l)" -eq 1 ] && [ -d "${SRC}/drivers/ufs" ] || {
  echo "ERROR: expected exactly one extracted kernel source dir with drivers/ufs, got: '${SRC}'" >&2
  exit 1
}

# ufs_trace.h is included via a path relative to the kernel build tree, so add
# the driver directory to the include path.
KCPPFLAGS="-I${SRC}/drivers/ufs" make -C "${KDEVEL}" M="${SRC}/drivers/ufs" \
  CONFIG_SCSI_UFSHCD=m CONFIG_SCSI_UFSHCD_PCI=m CONFIG_SCSI_UFSHCD_PLATFORM=m \
  modules

# Reference module from the same kernel, to compare struct module layout.
STOCK_XZ=$(find "/usr/lib/modules/${KVER}/kernel/drivers/scsi" -name 'sd_mod.ko*' -print -quit)
[ -n "${STOCK_XZ}" ] || {
  echo "ERROR: no stock reference module found" >&2
  exit 1
}
STOCK="${WORK}/stock.ko"
case "${STOCK_XZ}" in
  *.xz) xz -dc "${STOCK_XZ}" >"${STOCK}" ;;
  *.zst) zstd -dc "${STOCK_XZ}" >"${STOCK}" ;;
  *) cp "${STOCK_XZ}" "${STOCK}" ;;
esac

this_module_size() {
  # No early `exit` in awk: it would SIGPIPE readelf and trip pipefail.
  readelf -SW "$1" | awk '$0 ~ / \.gnu\.linkonce\.this_module / && $0 !~ /rela/ {
    for (i = 1; i <= NF; i++) if ($i == "PROGBITS") { size = $(i + 3) } }
    END { if (size != "") print size }'
}
WANT=$(this_module_size "${STOCK}")
[ -n "${WANT}" ] || {
  echo "ERROR: could not read this_module size from stock module" >&2
  exit 1
}

for m in core/ufshcd-core host/ufshcd-pci host/ufshcd-pltfrm; do
  ko="${SRC}/drivers/ufs/${m}.ko"
  [ -f "${ko}" ] || {
    echo "ERROR: ${ko} was not built" >&2
    exit 1
  }
  vm=$(modinfo -F vermagic "${ko}")
  case "${vm}" in
    "${KVER} "*) ;;
    *)
      echo "ERROR: vermagic mismatch for ${ko}: '${vm}' (want ${KVER})" >&2
      exit 1
      ;;
  esac
  # This is the exact check the kernel performs at load time (ELF struct module
  # size). A mismatch means the module build config differs from the kernel's.
  got=$(this_module_size "${ko}")
  if [ "${got}" != "${WANT}" ]; then
    echo "ERROR: ${ko} this_module size 0x${got} != kernel's 0x${WANT}" >&2
    echo "The module was built with a config that differs from the kernel's." >&2
    exit 1
  fi
  cp "${ko}" "${OUT}/ufs/"
done

echo "${KVER}" >"${OUT}/kver"
echo "this_module size 0x${WANT} matches kernel for all modules (${ARCH})"
ls -la "${OUT}/ufs"
