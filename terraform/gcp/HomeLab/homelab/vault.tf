resource "google_project_service" "cloudkms" {
  project            = "homelab-${local.project_id}"
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "vault" {
  project      = "homelab-${local.project_id}"
  account_id   = "vault-unseal"
  display_name = "vault"
}

resource "google_service_account_iam_member" "vault" {
  service_account_id = google_service_account.vault.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:vault:vault-sa"
}

resource "google_kms_key_ring" "key_ring" {
  project  = "homelab-${local.project_id}"
  name     = "vault"
  location = "global"
}

# Create a crypto key for the key ring
resource "google_kms_crypto_key" "crypto_key" {
  name                       = "vault"
  key_ring                   = google_kms_key_ring.key_ring.id
  rotation_period            = "1209600s"
  destroy_scheduled_duration = "86400s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_key_ring_iam_binding" "vault_iam_kms_binding" {
  key_ring_id = google_kms_key_ring.key_ring.id

  role = "roles/owner"

  members = [
    "serviceAccount:${google_service_account.vault.email}",
  ]
}
