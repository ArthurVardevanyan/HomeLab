resource "truenas_dataset" "backup_file_storage" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "File_Storage"
  pbkdf2iters      = 0
  pool             = "backup"
  quota_bytes      = 1073741824000
  readonly         = "off"
  record_size      = "128K"
  ref_quota_bytes  = 805306368000
  snap_dir         = "hidden"
  sync             = "standard"

}

resource "truenas_dataset" "backup_kubernetes" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "Kubernetes"
  pbkdf2iters      = 0
  pool             = "backup"
  quota_bytes      = 214748364800
  readonly         = "off"
  #record_size      = "1024K" "1M"
  ref_quota_bytes = 214748364800
  snap_dir        = "hidden"
  sync            = "standard"

}

resource "truenas_dataset" "backup_windows_backup" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "WindowsBackup"
  pbkdf2iters      = 0
  pool             = "backup"
  quota_bytes      = 805306368000
  readonly         = "off"
  #record_size      = "1024K" "1M"
  ref_quota_bytes = 805306368000
  snap_dir        = "hidden"
  sync            = "standard"

}

resource "truenas_dataset" "backup_s3" {
  atime            = "on"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "S3"
  pbkdf2iters      = 0
  pool             = "backup"
  quota_bytes      = 0
  readonly         = "off"
  #record_size      = "1024K" "1M"
  ref_quota_bytes = 0
  snap_dir        = "hidden"
  sync            = "standard"

}

resource "truenas_dataset" "backup_ix_applications" {
  atime            = "off"
  case_sensitivity = "sensitive"
  compression      = "lz4"
  copies           = 1
  deduplication    = "off"
  encrypted        = false
  exec             = "on"
  name             = "ix-applications"
  pbkdf2iters      = 0
  pool             = "backup"
  quota_bytes      = 0
  readonly         = "off"
  record_size      = "128K"
  ref_quota_bytes  = 0
  snap_dir         = "hidden"
  sync             = "standard"

}
