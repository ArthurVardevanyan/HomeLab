
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.7.4"
    }
  }
}

terraform {
  backend "local" {
    workspace_dir = "/mnt/storage/okd/terraform/bootstrap"
    path          = "/mnt/storage/okd/terraform/bootstrap/terraform.tfstate"
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
