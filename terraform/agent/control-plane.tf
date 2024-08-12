


resource "libvirt_volume" "control_plane" {
  count  = var.control_plane_count
  name   = "control-plane-${count.index}"
  pool   = libvirt_pool.okd.name
  size   = "137438953472"
  format = "raw"
}

resource "libvirt_domain" "control_plane" {
  count = var.control_plane_count
  name  = "control-plane-${count.index}"

  vcpu   = "6"     # 3
  memory = "18432" # 13312

  disk {
    volume_id = element(libvirt_volume.control_plane.*.id, count.index)
  }

  disk {
    file = "/mnt/storage/okd/okd/agent.x86_64.iso"
  }

  boot_device {
    dev = ["hd", "cdrom"]
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
    addresses    = ["${var.control_plane.ip}${count.index}"]
    mac          = "${var.control_plane.mac}${count.index}"
  }
}
