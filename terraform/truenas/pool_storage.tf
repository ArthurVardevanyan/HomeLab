resource "truenas_dataset" "storage_file_storage" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "File_Storage"
  pbkdf2iters      = 0
  pool             = "storage"
  quota_bytes      = 966367641600
  readonly         = "off"
  record_size      = "128K"
  ref_quota_bytes  = 805306368000
  snap_dir         = "hidden"
  sync             = "standard"

}

resource "truenas_dataset" "storage_kubernetes" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "Kubernetes"
  pbkdf2iters      = 0
  pool             = "storage"
  quota_bytes      = 214748364800
  readonly         = "off"
  #record_size      = "1024K" "1M"
  ref_quota_bytes = 214748364800
  snap_dir        = "hidden"
  sync            = "standard"

}
