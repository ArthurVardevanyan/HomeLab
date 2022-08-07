variable "path" {
  type        = string
  description = "Storage Path"
  default     = "/mnt/storage/okd"
}

variable "bootstrap" {
  type = object({
    mac = string
    ip  = string
  })
  default = {
    mac = "10:10:00:00:00:09"
    ip  = "10.10.10.9"
  }
}

variable "pool" {
  type        = string
  description = "The name of the storage pool."
}

variable "base_volume_id" {
  type        = string
  description = "The ID of the base volume for the bootstrap node."
}
