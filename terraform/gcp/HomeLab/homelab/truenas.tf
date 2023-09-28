
resource "google_storage_bucket" "truenas_nextcloud" {
  name          = "truenas_homelab_nextcloud"
  location      = "US"
  project       = "homelab-${local.project_id}"
  force_destroy = false

  autoclass {
    enabled = true
  }

  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
}

resource "google_service_account" "truenas_nextcloud" {
  project      = "homelab-${local.project_id}"
  account_id   = "truenas-nextcloud"
  display_name = "truenas-nextcloud"
}


resource "google_storage_bucket_iam_member" "truenas_nextcloud" {
  bucket = google_storage_bucket.truenas_nextcloud.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.truenas_nextcloud.member
}

resource "google_project_iam_custom_role" "truenas_nextcloud" {
  project     = "homelab-${local.project_id}"
  role_id     = "storage_buckets_list"
  title       = "storage_buckets_list"
  description = "storage_buckets_list"
  permissions = ["storage.buckets.list"]
}


resource "google_project_iam_member" "project" {
  project = "homelab-${local.project_id}"
  role    = google_project_iam_custom_role.truenas_nextcloud.id
  member  = google_service_account.truenas_nextcloud.member
}

resource "time_rotating" "truenas_nextcloud" {
  rotation_days = 90
}

resource "google_service_account_key" "truenas_nextcloud" {
  service_account_id = google_service_account.truenas_nextcloud.name

  keepers = {
    rotation_time = time_rotating.truenas_nextcloud.rotation_rfc3339
  }
}

resource "google_secret_manager_secret" "truenas_nextcloud" {
  project   = "homelab-${local.project_id}"
  secret_id = "truenas_nextcloud"

  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_version" "truenas_nextcloud" {
  secret      = google_secret_manager_secret.truenas_nextcloud.id
  secret_data = base64decode(google_service_account_key.truenas_nextcloud.private_key)
}

resource "google_storage_bucket" "homelab-tf-bucket" {
  name          = "tf-state-truenas-${local.bucket_id}"
  location      = "us-central1"
  project       = "homelab-${local.project_id}"
  force_destroy = true

  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
}
