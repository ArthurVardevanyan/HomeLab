
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.1"
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
