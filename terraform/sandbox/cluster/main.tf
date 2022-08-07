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

terraform {
  backend "local" {
    workspace_dir = "/mnt/storage/okd/terraform/cluster"
    path          = "/mnt/storage/okd/terraform/cluster/terraform.tfstate"
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
