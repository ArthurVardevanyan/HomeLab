resource "google_project_service" "cloudbuild" {
  project            = "homelab-${local.project_id}"
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

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
  #checkov:skip=CKV_GCP_78:These are temp files
  #checkov:skip=CKV_GCP_62:Access logs are not required.
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

  public_access_prevention    = "enforced"
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

resource "google_service_account_iam_member" "keep_alive" {
  service_account_id = google_service_account.keep_alive.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:keep-alive:keep-alive"
}


resource "google_secret_manager_secret" "discord_keep_alive" {
  project   = "homelab-${local.project_id}"
  secret_id = "discord_keep_alive"
  labels    = {}

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "secretAccessor" {
  project   = "homelab-${local.project_id}"
  secret_id = google_secret_manager_secret.discord_keep_alive.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:homelab-${local.project_id}@appspot.gserviceaccount.com"
}

resource "google_storage_bucket" "okd_homelab_keep_alive_cloud_function" {
  #checkov:skip=CKV_GCP_78:Versioning is Handleed by GitHub
  #checkov:skip=CKV_GCP_62:Access logs are not required.
  name                        = "okd_homelab_keep_alive_cloud_function"
  location                    = "US"
  project                     = "homelab-${local.project_id}"
  force_destroy               = true
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
}

locals {
  root_dir = abspath("./keep-alive")
}


data "archive_file" "keep_alive" {
  type        = "zip"
  source_dir  = local.root_dir
  output_path = "/tmp/keep_alive.zip"
}


resource "google_storage_bucket_object" "keep_alive" {
  name   = "${data.archive_file.keep_alive.output_md5}.zip"
  source = data.archive_file.keep_alive.output_path
  bucket = google_storage_bucket.okd_homelab_keep_alive_cloud_function.name
}

resource "google_storage_bucket_iam_member" "okd_homelab_keep_alive_cloud_function" {
  bucket = google_storage_bucket.okd_homelab_keep_alive_cloud_function.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.homelab_project_num}@cloudbuild.gserviceaccount.com"
}


resource "google_cloudfunctions_function" "okd_homelab_keep_alive_cloud_function" {
  available_memory_mb          = "128"
  entry_point                  = "KeepAlive"
  ingress_settings             = "ALLOW_ALL"
  source_archive_bucket        = google_storage_bucket.okd_homelab_keep_alive_cloud_function.name
  source_archive_object        = "${data.archive_file.keep_alive.output_md5}.zip"
  max_instances                = "3"
  name                         = "okd_homelab_keep_alive_cloud_function"
  project                      = "homelab-${local.project_id}"
  region                       = "us-central1"
  runtime                      = "go122"
  timeout                      = "60"
  trigger_http                 = true
  https_trigger_security_level = "SECURE_ALWAYS"

  environment_variables = {
    GCS_BUCKET    = "okd_homelab_keep_alive"
    ALLOWED_DELTA = "630" # 10.5 Minutes
  }

  secret_environment_variables {
    key    = "DISCORD"
    secret = "discord_keep_alive"
    # checkov:skip=CKV_SECRET_6 Place Holder
    version = "latest"
  }

  depends_on = [google_storage_bucket_object.keep_alive]

}

resource "google_cloudfunctions_function_iam_member" "member" {
  project        = "homelab-${local.project_id}"
  region         = "us-central1"
  cloud_function = google_cloudfunctions_function.okd_homelab_keep_alive_cloud_function.name
  role           = "roles/cloudfunctions.invoker"
  member         = google_service_account.keep_alive.member
}

resource "google_cloud_scheduler_job" "okd_homelab_keep_alive_cloud_function" {
  name             = "okd_homelab_keep_alive_cloud_function"
  description      = "okd_homelab_keep_alive_cloud_function"
  schedule         = "*/15 * * * *"
  time_zone        = "America/New_York"
  attempt_deadline = "60s"
  project          = "homelab-${local.project_id}"
  region           = "us-central1"

  retry_config {
    retry_count = 1
  }



  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions_function.okd_homelab_keep_alive_cloud_function.https_trigger_url
    body        = base64encode("{}")

    oidc_token {
      service_account_email = google_service_account.keep_alive.email
    }

  }
}
