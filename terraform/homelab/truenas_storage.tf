# resource "truenas_dataset" "storage_file_storage" {
#   atime            = "on"
#   case_sensitivity = "sensitive"
#   compression      = "lz4"
#   copies           = 1
#   deduplication    = "off"
#   encrypted        = false
#   exec             = "on"
#   name             = "File_Storage"
#   pbkdf2iters      = 0
#   pool             = "storage"
#   quota_bytes      = 966367641600
#   readonly         = "off"
#   record_size      = "128K"
#   ref_quota_bytes  = 805306368000
#   snap_dir         = "hidden"
#   sync             = "standard"

# }

# https://github.com/dariusbakunas/terraform-provider-truenas/issues/20
# resource "truenas_share_nfs" "storage_file_storage_nextcloud" {
#   paths = [
#     "/mnt/storage/File_Storage/Nextcloud",
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
