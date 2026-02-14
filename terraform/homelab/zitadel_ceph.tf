# ceph dashboard sso setup saml2 https://ceph.okd.homelab.arthurvardevanyan.com https://zitadel.arthurvardevanyan.com/saml/v2/metadata UserName
# ceph dashboard ac-user-create ArthurVardevanyan
# ceph dashboard ac-user-create ArthurVardevanyan --force-password --enabled -i /tmp/pass
# ceph dashboard ac-user-add-roles ArthurVardevanyan administrator
resource "zitadel_project" "ceph" {
  name                     = "ceph"
  org_id                   = zitadel_org.zitadel.id
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

data "http" "get_ceph_saml" {
  url = "https://ceph.okd.homelab.arthurvardevanyan.com/auth/saml2/metadata"
}

resource "zitadel_application_saml" "ceph" {
  org_id       = zitadel_org.zitadel.id
  project_id   = zitadel_project.ceph.id
  name         = "ceph"
  metadata_xml = data.http.get_ceph_saml.response_body
}
