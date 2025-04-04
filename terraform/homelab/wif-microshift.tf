resource "google_storage_bucket" "microshift_homelab_wif_oidc" {
  #checkov:skip=CKV_GCP_78:Versioning is handled by GitHub
  #checkov:skip=CKV_GCP_62:Access logs are not required.
  #checkov:skip=CKV_GCP_114:This Bucket Needs to be Public
  name          = "microshift-homelab-wif-oidc"
  location      = "US"
  project       = "homelab-${local.project_id}"
  force_destroy = true

  public_access_prevention    = "inherited"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "microshift_homelab_wif_oidc_public" {
  #checkov:skip=CKV_GCP_28:This Bucket Needs to be Public
  bucket = google_storage_bucket.microshift_homelab_wif_oidc.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "microshift-openid-configuration" {
  name   = ".well-known/openid-configuration"
  source = "wif-microshift/.well-known/openid-configuration"
  bucket = google_storage_bucket.microshift_homelab_wif_oidc.name
}

resource "google_storage_bucket_object" "microshift-keys-json" {
  name   = "keys.json"
  source = "wif-microshift/keys.json"
  bucket = google_storage_bucket.microshift_homelab_wif_oidc.name
}

resource "google_iam_workload_identity_pool" "microshift_homelab_wif" {
  workload_identity_pool_id = "microshift-homelab-wif"
  display_name              = "microshift-homelab-wif"
  description               = "Created By TF"
  project                   = "homelab-${local.project_id}"
}

resource "google_iam_workload_identity_pool_provider" "microshift_homelab_wif" {
  #checkov:skip=CKV_GCP_118:Allow any identity to authenticate
  display_name                       = "microshift-homelab-wif"
  project                            = "homelab-${local.project_id}"
  description                        = "Created By TF"
  workload_identity_pool_id          = google_iam_workload_identity_pool.microshift_homelab_wif.workload_identity_pool_id
  workload_identity_pool_provider_id = "microshift-homelab-wif"
  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  oidc {
    issuer_uri        = "https://storage.googleapis.com/${google_storage_bucket.microshift_homelab_wif_oidc.name}"
    allowed_audiences = ["microshift"]
  }
}

resource "google_service_account_iam_member" "wif_test_wif_binding_microshift" {
  service_account_id = google_service_account.wif_test.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.microshift_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:smoke-tests:wif-test"
}
