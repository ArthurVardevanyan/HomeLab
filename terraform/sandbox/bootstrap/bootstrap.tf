resource "libvirt_ignition" "bootstrap" {
  name    = "bootstrap-tf.ign"
  pool    = var.pool
  content = "${var.path}/okd/bootstrap.ign"
}

resource "libvirt_volume" "bootstrap" {
  name           = "bootstrap.raw"
  base_volume_id = var.base_volume_id
  pool           = var.pool
  size           = "17179869184" # 16 GIB
}

resource "libvirt_domain" "bootstrap" {
  name            = "bootstrap"
  coreos_ignition = libvirt_ignition.bootstrap.id

  vcpu   = "4"
  memory = "12288"
  disk {
    volume_id = libvirt_volume.bootstrap.id
  }

  console {
    type        = "pty"
    target_port = 0
  }

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_name = "okd"
    addresses    = ["${var.bootstrap.ip}"]
    mac          = var.bootstrap.mac
  }
}
