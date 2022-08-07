variable "os" {
  type        = string
  description = "Federoa CoreOS Version"
  default     = "36.20220716.3.1"
}

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

variable "master" {
  type = object({
    mac = string
    ip  = string
  })
  default = {
    mac = "10:10:00:00:00:1"
    ip  = "10.10.10.1"
  }
}

variable "master_count" {
  type        = string
  description = "The number of master nodes."
  default     = "3"
}
