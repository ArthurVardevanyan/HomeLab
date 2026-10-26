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
2. `ufs-builder` stage runs `build-ufs-modules.sh`, which installs
   `kernel-devel-<kver>` (the distro's exact `.config`, `Module.symvers` and
   generated headers), downloads the matching kernel source RPM, extracts only
   `drivers/ufs` and `include/ufs`, and builds with
   `make -C /usr/src/kernels/<kver> M=<src>/drivers/ufs CONFIG_SCSI_UFSHCD=m ...`.
   The CentOS kernel has no devfreq/OPP; the driver compiles cleanly without
   them against these headers.
3. Final stage copies the `.ko` files to
   `/usr/lib/modules/<kver>/extra/ufs/`, runs `depmod`, writes
   `/usr/lib/dracut/dracut.conf.d/99-ufs.conf` and regenerates the image's
   initramfs with `dracut --no-hostonly`.

Build-time guards (any failure stops the build):

- `WITH_UFS` must be `0` or `1`; empty or other values fail rather than silently
  skipping. `make image` also checks the built image's initramfs for
  `ufshcd-core` and `ufshcd-pci`.
- `kernel-devel-<kver>` must exist for the image's exact kernel. There is no
  fallback to a regenerated config or a different kernel. If the mirror lags
  behind the base image's kernel, the build fails with a clear message; retry
  once it catches up.
- Each module's vermagic must equal the kernel version, and its
  `.gnu.linkonce.this_module` ELF section size must equal that of a stock module
  from the same kernel (the check the kernel makes when loading).

Build with `WITH_UFS=0` to skip all of this. Modules are **unsigned**, so Secure
Boot must be off (it is on the S100). Because the modules are rebuilt on every
image build, `bootc upgrade` keeps them in sync with whatever kernel the new
image carries.

Caveat: the kernel source RPM is fetched from `mirror.stream.centos.org`,
falling back to `composes.stream.centos.org`.

#### Past failure: `.gnu.linkonce.this_module section size must match`

The first working-looking build copied the kernel's `.config` out of
`/usr/lib/modules` and ran `make olddefconfig` in a source tree. The build
container had no `pahole`, so `CONFIG_DEBUG_INFO_BTF` turned itself off, which
in turn dropped `CONFIG_SCHED_CLASS_EXT` / `CONFIG_EXT_GROUP_SCHED`. Those
change `sizeof(struct module)`: our modules had a 0x540-byte `this_module`
section versus 0x580 in stock CentOS modules, so the kernel refused to load
them at boot even though the version string matched. Building against
`kernel-devel` avoids regenerating the config altogether.

### Install workflow (Fedora Live + `bootc install`)

The Anaconda ISO still cannot see the disk (installer kernel has no UFS), so
install from a Fedora Live USB, whose kernel does:

1. Boot a Fedora Live USB on the S100.
2. Keep container storage in RAM. The live root is a small overlay and cannot
   hold the ~2.4 GB image. Mount tmpfs at the **default** paths so nothing else
   needs to change, then pull as root:

   ```bash
   sudo mkdir -p /var/lib/containers /var/tmp
   sudo mount -t tmpfs -o size=6G tmpfs /var/lib/containers
   sudo mount -t tmpfs -o size=2G tmpfs /var/tmp   # podman stages layers here
   sudo podman pull <registry>/homelab/microshift-bootc:<tag>
   ```

   tmpfs only consumes RAM as it fills. Always use `sudo`: rootless podman
   stores images under `~/.local/share/containers`, which `bootc` cannot see.

   The storage location and the `-v ...:/var/lib/containers` mount in the next
   step must point at the same place. If you use a custom root instead (for
   example `sudo podman --root /dev/shm/podman-ram ...`), pass `--root` to both
   the pull and the run, and mount `-v /dev/shm/podman-ram:/var/lib/containers`.
   Otherwise `bootc` sees an empty store. Note `/dev/shm` is capped at half of
   RAM by default.
3. Install the image straight to disk:

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
4. Reboot. The installed system boots with its own kernel, whose initramfs
   now contains the UFS modules.

### Verify

Check the image contents:

```bash
podman run --rm --entrypoint bash localhost/microshift-bootc:latest -c '
  K=$(ls /usr/lib/modules)
  modinfo -k "$K" -F depends ufshcd-pci
  lsinitrd /usr/lib/modules/$K/initramfs.img | grep ufshcd'
```

Boot the image's own kernel and initramfs against an emulated UFS controller
(QEMU `-device ufs`, PCI `1b36:0013`, handled by `ufshcd-pci`). Extract with
`podman cp` from a `podman create`d container, then:

```bash
truncate -s 1G ufs.img
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -nographic -no-reboot \
  -kernel vmlinuz -initrd initramfs.img \
  -append "console=ttyS0 root=UUID=00000000-dead-beef-0000-000000000000 rd.timeout=15 loglevel=7" \
  -drive file=ufs.img,if=none,id=lu0,format=raw \
  -device ufs,id=ufs0 -device ufs-lu,drive=lu0,bus=ufs0,lun=0
```

Expect `scsi host2: ufshcd`, `sd 2:0:0:0: [sda] Attached SCSI disk` and no
`size must match` error. The dracut timeout waiting for the fake root UUID is
expected. QEMU's emulated controller logs some `dme-get ... failed` lines that
real hardware will not. This was run on the build host (QEMU from a Fedora
container with `--device /dev/kvm`); real S100 hardware is still the final test.

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
