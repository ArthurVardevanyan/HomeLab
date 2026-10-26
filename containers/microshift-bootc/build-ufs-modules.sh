#!/usr/bin/env bash
# Build out-of-tree UFS host controller modules for the CentOS Stream 10 kernel
# installed in this image (the stock kernel ships with CONFIG_SCSI_UFSHCD unset).
#
# Needed for MinisForum S100 (Intel Alder Lake-N UFS, PCI 8086:54ff).
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
echo "Building UFS modules for kernel ${KVER}"

dnf -y install gcc make elfutils-libelf-devel openssl-devel bc flex bison perl xz tar cpio rpm-build
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

rpm2cpio "${SRPM}" | cpio -idm --quiet "linux-*.tar.xz"
tar -xf linux-*.tar.xz
cd linux-*/

cp "/usr/lib/modules/${KVER}/config" .config
xz -dc "/usr/lib/modules/${KVER}/symvers.xz" >Module.symvers

# The CentOS kernel has no devfreq/OPP. Kconfig for SCSI_UFSHCD selects them,
# which would leave unresolved symbols at modpost, so drop the selects. If the
# driver ever needs other symbols the kernel lacks, modpost fails the build.
sed -i '/^\tselect PM_DEVFREQ$/d; /^\tselect DEVFREQ_GOV_SIMPLE_ONDEMAND$/d' drivers/ufs/Kconfig
sed -i 's/^# CONFIG_SCSI_UFSHCD is not set/CONFIG_SCSI_UFSHCD=m/' .config
cat >>.config <<'EOF'
CONFIG_SCSI_UFSHCD_PCI=m
CONFIG_SCSI_UFSHCD_PLATFORM=m
CONFIG_SCSI_UFS_BSG=y
EOF
# Unsigned modules: do not require the distro signing key.
sed -i 's/^CONFIG_MODULE_SIG_KEY=.*/CONFIG_MODULE_SIG_KEY=""/; s/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config

make olddefconfig
# KERNELRELEASE makes vermagic match the running kernel exactly.
make KERNELRELEASE="${KVER}" modules_prepare
make KERNELRELEASE="${KVER}" M=drivers/ufs modules

for m in core/ufshcd-core host/ufshcd-pci host/ufshcd-pltfrm; do
  ko="drivers/ufs/${m}.ko"
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
  cp "${ko}" "${OUT}/ufs/"
done

echo "${KVER}" >"${OUT}/kver"
ls -la "${OUT}/ufs"
