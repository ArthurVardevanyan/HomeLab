terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.1.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "3.21.0"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "1.2.0"

    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.3"
    }
    truenas = {
      source  = "dariusbakunas/truenas"
      version = "0.11.1"

    }
  }
}

provider "vault" {
  address = "https://vault.arthurvardevanyan.com"
}

provider "google" {
}

provider "truenas" {
  api_key  = local.api_key
  base_url = "https://truenas.arthurvardevanyan.com/api/v2.0"
}

provider "http" {
}
