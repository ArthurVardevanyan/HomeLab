

provider "zitadel" {
  domain           = "zitadel.apps.okd.arthurvardevanyan.com"
  insecure         = "false"
  port             = "443"
  jwt_profile_file = "/tmp/zitadel.json"
}


resource "zitadel_org" "zitadel" {
  name       = "ZITADEL"
  is_default = true
}

resource "zitadel_machine_user" "pipeline" {
  org_id            = zitadel_org.zitadel.id
  user_name         = "pipeline"
  name              = "pipeline"
  description       = "pipeline"
  with_secret       = true
  access_token_type = "ACCESS_TOKEN_TYPE_JWT"
}

resource "zitadel_machine_key" "pipeline" {
  org_id   = zitadel_org.zitadel.id
  user_id  = zitadel_machine_user.pipeline.id
  key_type = "KEY_TYPE_JSON"
}


resource "google_secret_manager_secret" "zitadel_pipeline" {
  project   = "homelab-${local.project_id}"
  secret_id = "zitadel_pipeline"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "zitadel_pipeline" {
  secret      = google_secret_manager_secret.zitadel_pipeline.id
  secret_data = zitadel_machine_key.pipeline.key_details
}

resource "zitadel_instance_member" "pipeline" {
  user_id = zitadel_machine_user.pipeline.id
  roles   = ["IAM_OWNER"]
}

resource "zitadel_org_member" "zitadel_pipeline" {
  org_id  = zitadel_org.zitadel.id
  user_id = zitadel_machine_user.pipeline.id
  roles   = ["ORG_OWNER"]
}


resource "zitadel_human_user" "arthur" {
  org_id            = zitadel_org.zitadel.id
  user_name         = "ArthurVardevanyan"
  first_name        = "Arthur"
  last_name         = "Vardevanyan"
  display_name      = "Arthur Vardevanyan"
  email             = local.user_domain
  is_email_verified = true
}


resource "zitadel_instance_member" "arthur" {
  user_id = zitadel_human_user.arthur.id
  roles   = ["IAM_OWNER"]
}

resource "zitadel_org_member" "zitadel_arthur" {
  org_id  = zitadel_org.zitadel.id
  user_id = zitadel_human_user.arthur.id
  roles   = ["ORG_OWNER"]
}

resource "zitadel_smtp_config" "default" {
  sender_address   = local.smtp_username
  sender_name      = "no-reply"
  tls              = true
  host             = local.smtp_host
  user             = local.smtp_username
  password         = local.smtp_password
  reply_to_address = local.smtp_username
}
