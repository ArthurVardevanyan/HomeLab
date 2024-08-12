
resource "libvirt_network" "okd" {
  name      = "okd"
  mode      = "nat"
  domain    = "okd.local"
  addresses = ["10.10.10.0/24"]

  dns {
    enabled    = true
    local_only = false
  }
}

resource "libvirt_pool" "okd" {
  name = "okd"
  type = "dir"
  path = "${var.path}/vm"
}
