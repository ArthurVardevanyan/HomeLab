#!/usr/bin/env bash
set -euo pipefail

BINFMT=/proc/sys/fs/binfmt_misc
DEST=/opt/qemu-user-static
INTERP=$DEST/qemu-aarch64-static

# Fallback: if the host's binfmt is not mounted (or not writable), mount it.
# In the per-userns design (6.12+), a mount inside the pod's init userns
# lands in the shared init binfmt instance, making entries visible to all pods.
if [ ! -w "$BINFMT/register" ]; then
  echo "binfmt_misc not writable, mounting..." >&2
  mount -t binfmt_misc binfmt_misc "$BINFMT"
fi

mkdir -p "$DEST"

# Install the qemu binary onto the node filesystem (survives pod restarts).
# This lets the F-flag pinned entry survive a temporary DaemonSet gap.
install -m 0755 /usr/bin/qemu-aarch64-static "$DEST/"

register() {
  # Remove stale entry from a previous incarnation (its pinned file is dead).
  [ -e "$BINFMT/qemu-aarch64" ] && rm -f "$BINFMT/qemu-aarch64"
  # shellcheck disable=SC2028
  echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xfe:'"$INTERP"':F' \
    > "$BINFMT/register"
}

register

echo "binfmt aarch64 handler registered (flags: F, interp: $INTERP)" >&2

# Self-heal: re-register every 60s if the entry disappeared or was disabled.
while :; do
  sleep 60
  if [ ! -e "$BINFMT/qemu-aarch64" ] || \
     [ "$(cat "$BINFMT/qemu-aarch64")" != "enabled" ]; then
    echo "Handler missing/disabled, re-registering..." >&2
    register
  fi
done
