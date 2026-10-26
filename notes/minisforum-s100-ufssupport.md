# MinisForum S100 UFS Support

## Problem

The MinisForum S100 uses UFS (Universal Flash Storage) instead of traditional NVMe or SATA. Without UFS kernel modules in the initramfs, the system cannot boot from internal storage. Multiple Linux distributions (Ubuntu, Kubuntu 22.10/24.04, others) fail with:

```text
UUID=xxx does not exist. Dropping to a shell.
```

This happens because the UFS controller driver (`ufshcd`) is not loaded early enough in the boot process.

## References

- **Reddit thread (r/MiniPCs)**: <https://www.reddit.com/r/MiniPCs/comments/1eb8dgv/minisforum_s100_only_runs_windows_anyone_else/>
  - OP: u/Think-Fly765 (mass deleted)
  - Solution by community: Add `ufshcd` and `ufshcd-pci` modules to initramfs
  
- **AskUbuntu**: <https://askubuntu.com/questions/1446115/install-ubuntu-22-10-on-the-computer-with-ufs-universal-flash-storage-showing-t>

## Traditional Fix (Ubuntu/Debian)

For manual installations on Ubuntu/Debian-based systems:

```bash
# Boot from USB installer
# Mount root partition to /mnt
sudo mount /dev/mapper/ubuntu-vg-ubuntu-lv /mnt
sudo mount /dev/sda2 /mnt/boot  # if separate boot partition

# Bind mount virtual filesystems
sudo mount --bind /dev "$PWD/dev"
sudo mount --bind /proc "$PWD/proc"
sudo mount --bind /sys "$PWD/sys"

# Chroot
sudo chroot "$PWD" /bin/bash --login

# Add UFS modules to initramfs
echo "ufshcd" >> /etc/initramfs-tools/modules
echo "ufshcd-pci" >> /etc/initramfs-tools/modules

# Rebuild initramfs
update-initramfs -u -k all

# Exit and reboot
exit
sudo reboot
```

For LVM setups, mount both root AND boot partitions before chrooting.

**Limitations**: Does not work for full disk encryption (FDE), ZFS with FDE, or TPM-based FDE.

## BootC Solution (microshift-bootc)

For our bootc-based images, we use dracut to inject UFS modules into the initramfs:

```dockerfile
# bootc.Containerfile
RUN mkdir -p /etc/dracut.conf.d && \
  echo 'add_drivers+="ufshcd ufshcd-pci"' > /etc/dracut.conf.d/ufshcd.conf && \
  echo 'add_dracutmodules+="dm"' >> /etc/dracut.conf.d/ufshcd.conf
```

This automatically includes the UFS modules when `bootc-image-builder` constructs the final ISO.

## Kernel Support Notes

- UFS support in Linux kernel is marked "experimental" (`CONFIG_UFSExperimental`)
- Required in kernel 5.19+ (CentOS 10 includes kernel 5.14+ which has UFS support)
- Modules: `ufshcd`, `ufshcd-pci`, `ufshcd-ccw` (CCW devices)

## Troubleshooting

### Verify modules are in initramfs

```bash
# After building the ISO and booting
lsinitrd /boot/initramfs-* | grep -i ufs
modprobe -l | grep ufs
```

### Check UFS module availability

```bash
modinfo ufshcd
modinfo ufshcd-pci
```

### Manual module loading (for recovery)

If modules aren't in initramfs but available on system:

```bash
# During initramfs emergency shell
modprobe ufshcd
modprobe ufshcd-pci
exit
```
