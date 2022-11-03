export HOME=/home/arthur
export NODE=worker-5
export VCPUS=4
export RAM_MB=20480
export IMAGE="/mnt/storage/okd/${NODE}.raw"
export IGNITION_CONFIG="${HOME}/vm/okd/worker.ign"
export SIZE="52G"
export MAC="10:00:00:00:01:15"

STORAGE_PATH="/mnt/storage/okd/${NODE}_storage.raw"
STORAGE_SIZE="320G"
qemu-img create "${STORAGE_PATH}" "${STORAGE_SIZE}" -f raw
STORAGE="--disk=\"${STORAGE_PATH}\"",cache=none

qemu-img create "${IMAGE}" "${SIZE}" -f raw
virt-resize --expand /dev/sda4 "${HOME}"/vm/okd/fedora-coreos-*.qcow2 "${IMAGE}"

virt-install \
  --connect="qemu:///system" \
  --name="${NODE}" \
  --vcpus="${VCPUS}" --memory="${RAM_MB}" \
  --os-variant="fedora-coreos-stable" \
  --import --graphics="none" \
  --network bridge=br0,mac="${MAC}" \
  --disk="${IMAGE},cache=none" ${STORAGE} \
  --noautoconsole \
  --cpu="host-passthrough" \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}"
