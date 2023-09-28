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
  name               = "windowsBackup"
  path               = "/mnt/backup/WindowsBackup"
  path_suffix        = ""
  purpose            = "DEFAULT_SHARE"
  recyclebin         = false
  ro                 = false
  shadowcopy         = true
  streams            = true
  timemachine        = false
}

# resource "truenas_share_nfs" "backup_file_storage_nextcloud" {
# }

# resource "truenas_share_nfs" "backup_kubernetes/mysqldump" {
# }
