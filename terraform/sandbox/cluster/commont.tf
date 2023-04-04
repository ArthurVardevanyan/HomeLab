
resource "libvirt_network" "okd" {
  name      = "okd"
  mode      = "nat"
  domain    = "okd.local"
  addresses = ["10.10.10.0/24"]

  dns {
    enabled    = true
    local_only = false
  }
}

resource "libvirt_pool" "okd" {
  name = "okd"
  type = "dir"
  path = "${var.path}/vm"
}

resource "null_resource" "download_federoa" {
  provisioner "local-exec" {
    command = "rm -rf ${var.path}/fedora-coreos-${var.os}-qemu.x86_64.qcow2.xz; wget -q https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/${var.os}/x86_64/fedora-coreos-${var.os}-qemu.x86_64.qcow2.xz -P ${var.path}/"
  }
}

resource "null_resource" "extract_federoa" {
  provisioner "local-exec" {
    command = "rm -rf ${var.path}/fedora-coreos-${var.os}-qemu.x86_64.qcow2; xz -d ${var.path}/fedora-coreos-${var.os}-qemu.x86_64.qcow2.xz"
  }
  depends_on = [
    null_resource.download_federoa
  ]
}

resource "libvirt_volume" "federoa" {
  name   = "federoa"
  pool   = libvirt_pool.okd.name
  source = "${var.path}/fedora-coreos-${var.os}-qemu.x86_64.qcow2"
  #format = "raw"

  depends_on = [
    null_resource.extract_federoa
  ]
}
