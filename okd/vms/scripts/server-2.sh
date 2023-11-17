export LIBGUESTFS_BACKEND=direct
export HOME=/home/arthur
export NODE=server-2
export VCPUS=5
export RAM_MB=19968
export IMAGE="/mnt/${NODE}/${NODE}.raw"
export IGNITION_CONFIG="/var/lib/libvirt/images/master.ign"
export SIZE="128G"
export MAC="10:00:00:00:01:02"

qemu-img create "${IMAGE}" "${SIZE}" -f raw
virt-resize --expand /dev/sda4 /var/lib/libvirt/images/fedora-coreos-*.qcow2 "${IMAGE}"

virt-install \
  --connect="qemu:///system" \
  --name="${NODE}" \
  --vcpus="${VCPUS}" --memory="${RAM_MB}" \
  --os-variant="fedora-coreos-stable" \
  --import --graphics="none" \
  --network bridge=br0,mac="${MAC}" \
  --disk="${IMAGE},cache=none" \
  --cpu="host-passthrough" \
  --noautoconsole \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}"
