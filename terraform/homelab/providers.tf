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
  }
}
