resource "google_service_account" "avgcp" {
  project      = "homelab-${local.project_id}"
  account_id   = "tf-avgcp"
  display_name = "tf-avgcp"
}

resource "google_service_account_iam_member" "avgcp-tc" {
  service_account_id = google_service_account.avgcp.id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.avgcp.member
}

resource "google_service_account_iam_member" "avgcp-au" {
  service_account_id = google_service_account.avgcp.id
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.avgcp.member
}

resource "google_storage_bucket" "avgcp" {
  name          = "terraform_provider_avgcp"
  location      = "US"
  project       = "homelab-${local.project_id}"
  force_destroy = true
}

resource "google_storage_bucket_iam_member" "avgcp" {
  bucket = google_storage_bucket.avgcp.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.avgcp.member
}

resource "google_service_account_iam_member" "avgcp-wif" {
  service_account_id = google_service_account.avgcp.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:tfm:pipeline"
}
