ui = true

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = "0"
  tls_cert_file = "/vault/cert/tls.crt"
  tls_key_file  = "/vault/cert/tls.key"
}

seal "gcpckms" {
  project     = "homelab-3753533735"
  region      = "global"
  key_ring    = "vault"
  crypto_key  = "vault"
}

storage "raft" {
  path = "/vault/data"
}

service_registration "kubernetes" {}

disable_mlock = true
