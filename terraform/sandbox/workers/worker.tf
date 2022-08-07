
resource "libvirt_ignition" "worker" {
  name    = "worker-tf.ign"
  pool    = var.pool
  content = "${var.path}/okd/worker.ign"
}

resource "libvirt_volume" "worker" {
  count          = var.worker_count
  name           = "worker-${count.index}"
  base_volume_id = var.base_volume_id
  pool           = var.pool
  size           = "55834574848" # 16 GIB
}

resource "libvirt_domain" "worker" {
  count           = var.worker_count
  name            = "worker-${count.index}"
  coreos_ignition = libvirt_ignition.worker.id

  vcpu   = "4"
  memory = "6144"
  disk {
    volume_id = element(libvirt_volume.worker.*.id, count.index)
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
    addresses    = ["${var.worker.ip}${count.index}"]
    mac          = "${var.worker.mac}${count.index}"
  }
}
