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
  quota_bytes      = 1099511627776
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
  name             = "s3"
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

resource "truenas_share_smb" "backup_windows_backup" {
  aapl_name_mangling = false
  abe                = false
  acl                = true
  auxsmbconf         = ""
  browsable          = true
  comment            = ""
  durablehandle      = true
  enabled            = true
  fsrvp              = false
  guestok            = false
  home               = false
  hostsallow         = []
  hostsdeny          = []
  name               = "WindowsBackup"
  path               = "/mnt/backup/WindowsBackup"
  path_suffix        = ""
  purpose            = "DEFAULT_SHARE"
  recyclebin         = false
  ro                 = false
  shadowcopy         = true
  streams            = true
  timemachine        = false
}

# https://github.com/dariusbakunas/terraform-provider-truenas/issues/20
# resource "truenas_share_nfs" "backup_file_storage_nextcloud" {
#   paths = [
#     "/mnt/backup/File_Storage/Nextcloud",
#   ]
#   comment       = ""
#   hosts         = []
#   networks      = []
#   alldirs       = false
#   enabled       = true
#   maproot_user  = null
#   maproot_group = null
#   mapall_user   = null
#   mapall_group  = null
#   quiet         = false
#   ro            = false
#   security      = []
# }
