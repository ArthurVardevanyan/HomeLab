terraform {
  backend "gcs" {}

}

provider "vault" {}

terraform {
  required_providers {
    truenas = {
      source  = "dariusbakunas/truenas"
      version = "0.11.1"
    }
  }
}


data "vault_generic_secret" "truenas" {
  path = "secret/truenas/api"
}

locals {
  api_key = data.vault_generic_secret.truenas.data["key"]
}

provider "truenas" {
  api_key  = local.api_key
  base_url = "https://truenas.arthurvardevanyan.com/api/v2.0"
}
