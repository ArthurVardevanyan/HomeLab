
variable "path" {
  type        = string
  description = "Storage Path"
  default     = "/mnt/storage/okd"
}

variable "control_plane" {
  type = object({
    mac = string
    ip  = string
  })
  default = {
    mac = "10:10:00:00:00:1"
    ip  = "10.10.10.1"
  }
}

variable "control_plane_count" {
  type        = string
  description = "The number of control plane nodes."
  default     = "3"
}
