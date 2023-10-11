export HOME=/home/arthur
export NODE=infra-2
export VCPUS=4
export RAM_MB=8192
export IMAGE="/var/lib/libvirt/images/${NODE}.raw"
export IGNITION_CONFIG="/var/lib/libvirt/images/worker.ign"
export SIZE="64G"
export MAC="10:00:00:00:01:22"

STORAGE_PATH="/mnt/storage/${NODE}_storage.raw"
STORAGE_SIZE="896G"
qemu-img create "${STORAGE_PATH}" "${STORAGE_SIZE}" -f raw
STORAGE="--disk=\"${STORAGE_PATH}\"",cache=none

STORAGE_PATH_1="/mnt/storage-1/${NODE}_storage.raw"
qemu-img create "${STORAGE_PATH_1}" "${STORAGE_SIZE}" -f raw
STORAGE_1="--disk=\"${STORAGE_PATH_1}\"",cache=none

qemu-img create "${IMAGE}" "${SIZE}" -f raw
virt-resize --expand /dev/sda4 /var/lib/libvirt/images/fedora-coreos-*.qcow2 "${IMAGE}"

virt-install \
    --connect="qemu:///system" \
    --name="${NODE}" \
    --vcpus="${VCPUS}" --memory="${RAM_MB}" \
    --os-variant="fedora-coreos-stable" \
    --import --graphics="none" \
    --network bridge=br0,mac="${MAC}" \
    --disk="${IMAGE},cache=none" ${STORAGE} ${STORAGE_1} \
    --noautoconsole \
    --cpu="host-passthrough" \
    --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}"
