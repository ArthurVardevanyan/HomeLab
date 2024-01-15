

resource "libvirt_ignition" "master" {
  name    = "master-tf.ign"
  pool    = "default" #libvirt_pool.okd.name
  content = "${var.path}/okd/master.ign"
}

resource "libvirt_volume" "master" {
  count          = var.master_count
  name           = "master-${count.index}"
  base_volume_id = libvirt_volume.federoa.id
  pool           = libvirt_pool.okd.name
  size           = "55834574848" # 16 GIB
  # format         = "raw" # TODO
}

resource "libvirt_domain" "master" {
  count           = var.master_count
  name            = "master-${count.index}"
  coreos_ignition = libvirt_ignition.master.id

  vcpu   = "3"
  memory = "13312"
  disk {
    volume_id = element(libvirt_volume.master.*.id, count.index)
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
    addresses    = ["${var.master.ip}${count.index}"]
    mac          = "${var.master.mac}${count.index}"
  }
}
