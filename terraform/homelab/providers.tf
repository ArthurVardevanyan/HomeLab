terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.20.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.7.0"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "2.7.0"

    }
    http = {
      source  = "hashicorp/http"
      version = "3.5.0"
    }
    # truenas = {
    #   source  = "dariusbakunas/truenas"
    #   version = "0.11.1"

    # }
  }
}

provider "vault" {
  address          = "https://vault.arthurvardevanyan.com"
  skip_child_token = true
}

provider "google" {
}

# provider "truenas" {
#   api_key  = local.api_key
#   base_url = "https://truenas.arthurvardevanyan.com/api/v2.0"
# }

provider "http" {
}
