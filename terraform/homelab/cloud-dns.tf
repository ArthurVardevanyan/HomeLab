
resource "google_project_service" "dns" {
  project            = "homelab-${local.project_id}"
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}


resource "google_dns_managed_zone" "homelab_okd" {
  name        = "homelab-okd"
  project     = "homelab-${local.project_id}"
  dns_name    = "okd.homelab.arthurvardevanyan.com."
  description = "okd HomeLab DNS"

  cloud_logging_config {
    enable_logging = true
  }

  dnssec_config {
    state = "on"
  }

}



resource "google_service_account" "cloud_dns" {
  project      = "homelab-${local.project_id}"
  account_id   = "cloud-dns"
  display_name = "cloud-dns"
}


resource "google_dns_managed_zone_iam_member" "cloud_dns" {
  project      = "homelab-${local.project_id}"
  managed_zone = google_dns_managed_zone.homelab_okd.name
  role         = "roles/dns.admin"
  member       = google_service_account.cloud_dns.member
}



resource "google_project_iam_member" "cloud_dns" {
  project = "homelab-${local.project_id}"
  role    = "roles/dns.reader"
  member  = google_service_account.cloud_dns.member

}

resource "google_service_account_iam_member" "cloud_dns" {
  service_account_id = google_service_account.cloud_dns.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.okd_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:cert-manager:cert-manager"
}

resource "google_service_account_iam_member" "cloud_dns_sno" {
  service_account_id = google_service_account.cloud_dns.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${local.homelab_project_num}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.sno_homelab_wif.workload_identity_pool_id}/subject/system:serviceaccount:cert-manager:cert-manager"
}
