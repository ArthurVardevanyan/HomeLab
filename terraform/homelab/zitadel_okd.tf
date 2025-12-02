resource "zitadel_project" "okd" {
  name                     = "okd"
  org_id                   = zitadel_org.zitadel.id
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}


resource "zitadel_application_oidc" "okd" {
  project_id = zitadel_project.okd.id
  org_id     = zitadel_org.zitadel.id

  name = "okd"
  redirect_uris = [
    "https://console-openshift-console.apps.okd.homelab.arthurvardevanyan.com/auth/callback",
    "https://oauth-openshift.apps.okd.homelab.arthurvardevanyan.com/oauth2callback/zitadel",
    "https://argocd.app.okd.homelab.arthurvardevanyan.com/auth/callback",
    "https://argocd-apps.app.okd.homelab.arthurvardevanyan.com/auth/callback",

    "https://console-openshift-console.apps.okd.virt.arthurvardevanyan.com/auth/callback",
    "https://oauth-openshift.apps.okd.virt.arthurvardevanyan.com/oauth2callback/zitadel",
    "https://argocd.app.okd.virt.arthurvardevanyan.com/auth/callback",
    "https://argocd-apps.app.okd.virt.arthurvardevanyan.com/auth/callback",

    "http://localhost:*"
  ]
  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types    = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  post_logout_redirect_uris = [
    "https://argocd.app.okd.homelab.arthurvardevanyan.com/auth/callback" # Can't remove this for some reason
  ]
  app_type                    = "OIDC_APP_TYPE_WEB"
  auth_method_type            = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version                     = "OIDC_VERSION_1_0"
  clock_skew                  = "0s"
  dev_mode                    = true # For http endpoint
  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = true
  additional_origins          = []
}



resource "google_secret_manager_secret" "zitadel_okd" {
  project   = "homelab-${local.project_id}"
  secret_id = "zitadel_okd"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "zitadel_okd" {
  secret      = google_secret_manager_secret.zitadel_okd.id
  secret_data = zitadel_application_oidc.okd.client_secret
}
