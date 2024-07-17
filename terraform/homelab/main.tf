terraform {
  backend "gcs" {}
}

provider "vault" {
  address = "https://vault.arthurvardevanyan.com"
}

provider "google" {
}

data "vault_generic_secret" "org" {
  path = "secret/gcp/org/av/projects"
}
data "vault_generic_secret" "homelab" {
  path = "secret/gcp/org/av/folders/homelab"
}

data "vault_generic_secret" "projects" {
  path = "secret/gcp/org/av/projects"
}

locals {
  project_id          = data.vault_generic_secret.org.data["project_id"]
  bucket_id           = data.vault_generic_secret.projects.data["bucket_id"]
  homelab_project_num = data.vault_generic_secret.homelab.data["homelab_project_num"]
  user                = data.vault_generic_secret.projects.data["user"]
}

resource "google_project_service" "compute" {
  project            = "homelab-${local.project_id}"
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  project            = "homelab-${local.project_id}"
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}



resource "google_service_account" "tekton" {
  project      = "homelab-${local.project_id}"
  account_id   = "tekton"
  display_name = "tekton"
}


resource "google_project_iam_member" "tekton" {
  #checkov:skip=CKV_GCP_49: Used for Automation
  #checkov:skip=CKV_GCP_117: Used for Automation
  project = "homelab-${local.project_id}"
  role    = "roles/owner"
  member  = google_service_account.tekton.member
}

resource "google_service_account_iam_member" "tekton" {
  #checkov:skip=CKV_GCP_49: Used for Automation
  service_account_id = google_service_account.tekton.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:homelab:pipeline"
}

resource "google_storage_bucket" "github-tf-bucket" {
  #checkov:skip=CKV_GCP_62:Access logs are not required.
  name                        = "tf-state-github-${local.bucket_id}"
  location                    = "us-central1"
  project                     = "homelab-${local.project_id}"
  force_destroy               = false
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

}
