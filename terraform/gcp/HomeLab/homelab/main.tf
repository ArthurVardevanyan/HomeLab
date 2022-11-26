terraform {
  backend "gcs" {}

}

provider "vault" {}

provider "google" {}
provider "google-beta" {}

data "vault_generic_secret" "org" {
  path = "secret/gcp/org/av/projects"
}
data "vault_generic_secret" "homelab" {
  path = "secret/gcp/org/av/folders/homelab"
}

locals {
  project_id          = data.vault_generic_secret.org.data["project_id"]
  homelab_project_num = data.vault_generic_secret.homelab.data["homelab_project_num"]
}

resource "google_project_service" "compute" {
  project            = "homelab-${local.project_id}"
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}
