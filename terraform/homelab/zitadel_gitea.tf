resource "zitadel_project" "gitea" {
  name                     = "gitea"
  org_id                   = zitadel_org.zitadel.id
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}


resource "zitadel_application_oidc" "gitea" {
  project_id = zitadel_project.gitea.id
  org_id     = zitadel_org.zitadel.id

  name = "gitea"
  redirect_uris = [
    "https://git.arthurvardevanyan.com/user/oauth2/Zitadel/callback",
  ]
  response_types              = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types                 = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  post_logout_redirect_uris   = []
  app_type                    = "OIDC_APP_TYPE_WEB"
  auth_method_type            = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version                     = "OIDC_VERSION_1_0"
  clock_skew                  = "0s"
  dev_mode                    = false
  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = false
  additional_origins          = []
}



resource "google_secret_manager_secret" "zitadel_gitea" {
  project   = "homelab-${local.project_id}"
  secret_id = "zitadel_gitea"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "zitadel_gitea" {
  secret      = google_secret_manager_secret.zitadel_gitea.id
  secret_data = zitadel_application_oidc.gitea.client_secret
}
