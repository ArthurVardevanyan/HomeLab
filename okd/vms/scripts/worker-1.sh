#!/bin/bash

export LIBGUESTFS_BACKEND=direct
export HOME=/home/arthur
export NODE=worker-1
export VCPUS=12
export RAM_MB=58368
export IMAGE="/mnt/storage/${NODE}.raw"
export IGNITION_CONFIG="/var/lib/libvirt/images/worker.ign"
export SIZE="320G"
export MAC="10:00:00:00:01:11"

qemu-img create "${IMAGE}" "${SIZE}" -f raw
# shellcheck disable=SC2089
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
