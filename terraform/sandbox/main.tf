###############
### TESTING ###
###############

# Permession Denied Issue
# https://github.com/jedi4ever/veewee/issues/996#issuecomment-497976612

# TF Provider
# https://github.com/dmacvicar/terraform-provider-libvirt
# https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs

# OpenShift Terraform Example
# https://github.com/openshift/installer/blob/master/docs/dev/libvirt/README.md
# https://github.com/openshift/installer/tree/master/data/data/libvirt/bootstrap

terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.6.14"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

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

  depends_on = [
    null_resource.extract_federoa
  ]
}
