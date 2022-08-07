output "pool" {
  value = libvirt_pool.okd.name
}

output "base_volume_id" {
  value = libvirt_volume.federoa.id
}
