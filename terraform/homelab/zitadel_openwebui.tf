resource "zitadel_project" "openwebui" {
  name   = "openwebui"
  org_id = zitadel_org.zitadel.id
  # Assert project roles so the Open WebUI role-mapping (ENABLE_OAUTH_ROLE_MANAGEMENT)
  # has something to map. Roles are flattened into a plain "roles" claim by the
  # action below (Open WebUI cannot parse Zitadel's native nested roles claim).
  project_role_assertion   = true
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}


resource "zitadel_application_oidc" "openwebui" {
  project_id = zitadel_project.openwebui.id
  org_id     = zitadel_org.zitadel.id

  name = "openwebui"
  redirect_uris = [
    "https://ai.arthurvardevanyan.com/oauth/oidc/callback",
  ]
  post_logout_redirect_uris = [
    "https://ai.arthurvardevanyan.com/auth",
  ]
  response_types              = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types                 = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type                    = "OIDC_APP_TYPE_WEB"
  auth_method_type            = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version                     = "OIDC_VERSION_1_0"
  clock_skew                  = "0s"
  dev_mode                    = false
  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  # Emit roles in the id_token and userinfo response (the path Open WebUI reads).
  id_token_role_assertion     = true
  id_token_userinfo_assertion = true
  additional_origins          = []
}


# ---------------------------------------------------------------------------
# Role-based access control for Open WebUI
#
# Open WebUI maps OIDC roles to its user/admin roles (ENABLE_OAUTH_ROLE_MANAGEMENT
# with OAUTH_ROLES_CLAIM=roles). Zitadel's native project-roles claim is a nested
# object which Open WebUI cannot parse, so the action below flattens granted role
# keys into a plain "roles" string array claim.
#
# DEPLOY ORDER: apply this Terraform BEFORE relying on the Open WebUI role gate.
# The admin user_grant ensures the sole user resolves to "admin" (not the
# DEFAULT_USER_ROLE=pending gate) on first login.
# ---------------------------------------------------------------------------

resource "zitadel_project_role" "openwebui_user" {
  org_id       = zitadel_org.zitadel.id
  project_id   = zitadel_project.openwebui.id
  role_key     = "user"
  display_name = "User"
}

resource "zitadel_project_role" "openwebui_admin" {
  org_id       = zitadel_org.zitadel.id
  project_id   = zitadel_project.openwebui.id
  role_key     = "admin"
  display_name = "Admin"
}

# Grant the primary user the admin role (lockout guard).
resource "zitadel_user_grant" "openwebui_arthur_admin" {
  org_id     = zitadel_org.zitadel.id
  project_id = zitadel_project.openwebui.id
  user_id    = zitadel_human_user.arthur.id
  role_keys  = ["admin"]

  depends_on = [
    zitadel_project_role.openwebui_admin,
  ]
}

# Flatten granted project roles into a plain "roles" claim (string array) that
# Open WebUI can parse. Runs on the pre-userinfo token-customise trigger.
resource "zitadel_action" "openwebui_roles" {
  org_id          = zitadel_org.zitadel.id
  name            = "openwebuiRoles"
  timeout         = "10s"
  allowed_to_fail = true
  script          = <<-EOT
    function openwebuiRoles(ctx, api) {
      var out = [];
      var grantList = ctx.v1.getUser().grants;
      if (grantList && grantList.grants) {
        grantList.grants.forEach(function (grant) {
          (grant.roles || []).forEach(function (role) {
            out.push(role);
          });
        });
      }
      api.v1.claims.setClaim('roles', out);
    }
  EOT
}

resource "zitadel_trigger_actions" "openwebui_roles" {
  org_id       = zitadel_org.zitadel.id
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = "TRIGGER_TYPE_PRE_USERINFO_CREATION"
  action_ids   = [zitadel_action.openwebui_roles.id]
}


resource "google_secret_manager_secret" "zitadel_openwebui" {
  project   = "homelab-${local.project_id}"
  secret_id = "zitadel_openwebui"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "zitadel_openwebui" {
  secret      = google_secret_manager_secret.zitadel_openwebui.id
  secret_data = zitadel_application_oidc.openwebui.client_secret
}