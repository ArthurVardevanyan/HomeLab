
resource "google_project_service" "cloudfunctions" {
  project            = "homelab-${local.project_id}"
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}


resource "google_project_service" "cloudscheduler" {
  project            = "homelab-${local.project_id}"
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "okd_homelab_keep_alive" {
  name          = "okd_homelab_keep_alive"
  location      = "US"
  project       = "homelab-${local.project_id}"
  force_destroy = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age        = 1
      with_state = "ANY"
    }
  }

  uniform_bucket_level_access = true
}

resource "google_service_account" "keep_alive" {
  project      = "homelab-${local.project_id}"
  account_id   = "keep-alive"
  display_name = "keep alive"
}


resource "google_storage_bucket_iam_member" "keep_alive" {
  bucket = google_storage_bucket.okd_homelab_keep_alive.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.keep_alive.member
}

# resource "google_storage_bucket_object" "keys-json" {
#   name   = "keep-alive.zip"
#   source = "keep-alive/keep-alive.zip"
#   bucket = google_storage_bucket.okd_homelab_wif_oidc.name
# }


resource "google_service_account_iam_member" "keep_alive" {
  service_account_id = google_service_account.keep_alive.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:keep-alive:keep-alive"
}
