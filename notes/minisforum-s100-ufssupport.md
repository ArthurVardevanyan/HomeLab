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

### Root cause (observed on the S100)

The CentOS Stream 10 kernel (and ELRepo `kernel-ml`) is built without UFS
(`# CONFIG_SCSI_UFSHCD is not set`), so no `ufshcd*` modules exist for it. The
Anaconda installer ISO uses the same kernel, so it cannot see the internal
disk at all. The Fedora Live kernel does ship UFS: the controller shows up in
`lspci` as `Alder Lake-N UFS Controller` (PCI `8086:54ff`) and the 128 GB disk
appears as `/dev/sda`.

A dracut drop-in alone (`add_drivers+="ufshcd ufshcd-pci"`) cannot work, because
there are no modules to include.

### Fix: build the UFS modules into the image

`bootc.Containerfile` builds the modules out-of-tree against the exact kernel
in the image:

1. `os-base` stage runs `dnf -y update` once, so every later stage sees the
   same kernel.
2. `ufs-builder` stage runs `build-ufs-modules.sh`: downloads the matching
   kernel source RPM from CentOS Stream, enables
   `CONFIG_SCSI_UFSHCD{,_PCI,_PLATFORM}=m` on top of the image's own kernel
   config, and builds `drivers/ufs` with `KERNELRELEASE` set so the vermagic
   matches. It drops the Kconfig `select PM_DEVFREQ` because the CentOS kernel
   has no devfreq/OPP (otherwise modpost reports unresolved symbols).
3. Final stage copies the `.ko` files to
   `/usr/lib/modules/<kver>/extra/ufs/`, runs `depmod`, writes
   `/etc/dracut.conf.d/ufshcd.conf` and regenerates the image's initramfs with
   `dracut --no-hostonly`. The build fails if `ufshcd-pci` is not in the
   initramfs, or if the modules were built for a different kernel.

Build with `WITH_UFS=0` to skip all of this (e.g. for hardware that does not
need it). Modules are **unsigned**, so Secure Boot must be off (it is on the
S100). Because the modules are rebuilt on every image build, `bootc upgrade`
keeps them in sync with whatever kernel the new image carries.

Caveat: the source RPM is fetched from `mirror.stream.centos.org`, falling
back to `composes.stream.centos.org`. The mirror only keeps a few recent
kernels and can lag behind the base image, so a build can fail if neither has
the exact kernel version. Re-run once the mirror catches up.

### Install workflow (Fedora Live + `bootc install`)

The Anaconda ISO still cannot see the disk (installer kernel has no UFS), so
install from a Fedora Live USB, whose kernel does:

1. Boot a Fedora Live USB on the S100.
2. Install the image straight to disk:

   ```bash
   sudo podman run --rm --privileged --pid=host --entrypoint bootc \
     -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
     --security-opt label=type:unconfined_t \
     <registry>/homelab/microshift-bootc:<tag> \
     install to-disk --wipe /dev/sda
   ```

   `make install-live` in `containers/microshift-bootc/` prints this command.
   `--entrypoint bootc` is required for images built before the image's
   `ENTRYPOINT` was removed; otherwise podman runs the old entrypoint script and
   hangs on "Waiting for MicroShift to start".
3. Reboot. The installed system boots with its own kernel, whose initramfs
   now contains the UFS modules.

### Verify

```bash
podman run --rm localhost/microshift-bootc:latest bash -c '
  K=$(ls /usr/lib/modules)
  modinfo -k "$K" -F depends ufshcd-pci
  lsinitrd /usr/lib/modules/$K/initramfs.img | grep ufshcd'
```

The first real test is booting the S100 from `/dev/sda`; this has been
verified at image-build level only.

## Kernel Support Notes

- UFS host controller support is an in-tree driver (`drivers/ufs/`), not
  enabled in the CentOS Stream 10 kernel config.
- Modules involved: `ufshcd-core`, `ufshcd-pci`, `ufshcd-pltfrm`.

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
