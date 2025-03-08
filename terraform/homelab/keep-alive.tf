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

resource "google_project_service" "cloud_run" {
  project            = "homelab-${local.project_id}"
  service            = "run.googleapis.com"
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

resource "google_service_account_iam_member" "keep_alive_sno" {
  service_account_id = google_service_account.keep_alive.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.sno_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:keep-alive:keep-alive"
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
  member    = "serviceAccount:${google_service_account.keep_alive.email}"
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


resource "google_cloudfunctions2_function" "okd_homelab_keep_alive_cloud_function" {
  name     = "okd-homelab-keep-alive-cloud-function"
  project  = "homelab-${local.project_id}"
  location = "us-central1"


  build_config {
    runtime           = "go123"
    entry_point       = "KeepAlive"
    docker_repository = "projects/homelab-${local.project_id}/locations/us-central1/repositories/gcf-artifacts"
    source {
      storage_source {
        bucket = google_storage_bucket.okd_homelab_keep_alive_cloud_function.name
        object = "${data.archive_file.keep_alive.output_md5}.zip"
      }
    }
    environment_variables = {
      GCS_BUCKET    = "okd_homelab_keep_alive"
      ALLOWED_DELTA = "630" # 10.5 Minutes
    }

  }
  service_config {
    service_account_email = google_service_account.keep_alive.email
    available_memory      = "128Mi"
    max_instance_count    = 3
    timeout_seconds       = 60
    ingress_settings      = "ALLOW_ALL"
    environment_variables = {
      LOG_EXECUTION_ID = "true"
    }
    secret_environment_variables {
      key        = "DISCORD"
      project_id = "homelab-${local.project_id}"
      secret     = "discord_keep_alive"
      version    = "latest"
    }

  }

  depends_on = [google_storage_bucket_object.keep_alive]
}

resource "google_cloudfunctions2_function_iam_member" "member" {
  project        = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.project
  location       = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.location
  cloud_function = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.name
  role           = "roles/cloudfunctions.invoker"
  member         = google_service_account.keep_alive.member
}


resource "google_cloud_run_service_iam_member" "cloud_run_invoker" {
  project  = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.project
  location = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.location
  service  = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.name
  role     = "roles/run.invoker"
  member   = google_service_account.keep_alive.member
}

resource "google_cloud_scheduler_job" "okd_homelab_keep_alive_cloud_function" {
  name             = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.name
  description      = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.name
  schedule         = "*/15 * * * *"
  time_zone        = "America/New_York"
  attempt_deadline = "60s"
  project          = "homelab-${local.project_id}"
  region           = "us-central1"

  retry_config {
    retry_count = 1
  }



  http_target {
    uri         = google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.service_config[0].uri
    http_method = "POST"
    body        = base64encode("{}")
    oidc_token {
      audience              = "${google_cloudfunctions2_function.okd_homelab_keep_alive_cloud_function.service_config[0].uri}/"
      service_account_email = google_service_account.keep_alive.email
    }
  }

}
