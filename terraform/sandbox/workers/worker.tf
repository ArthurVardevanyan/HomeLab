
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
  size           = "68719476736" # 64 GIB
  # format         = "raw" # TODO
}

resource "libvirt_volume" "worker-storage" {
  count  = var.worker_count
  name   = "worker-storage-${count.index}"
  pool   = var.pool
  size   = "103079215104" # 96 GIB
  format = "raw"
}

resource "libvirt_domain" "worker" {
  count           = var.worker_count
  name            = "worker-${count.index}"
  coreos_ignition = libvirt_ignition.worker.id

  vcpu   = "4"
  memory = "8192"
  disk {
    volume_id = element(libvirt_volume.worker.*.id, count.index)
  }
  disk {
    volume_id = element(libvirt_volume.worker-storage.*.id, count.index)
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
