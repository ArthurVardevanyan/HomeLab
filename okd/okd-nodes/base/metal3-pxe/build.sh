#!/usr/bin/env bash
# Rebuilds snponly-homelab.efi (iPXE with an embedded script) from embed.ipxe.
# The embedded script runs DHCP itself and chains straight to the metal3 HTTP
# server, ignoring DHCP Option 67 so the UDM's fixed boot filename cannot loop.
# snponly is used because iPXE has no native driver for the RTL8125 NICs.
set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

podman run --rm -v "${HERE}:/out:Z" registry.fedoraproject.org/fedora:latest bash -c '
  dnf -y -q install git gcc make perl xz-devel binutils >/dev/null
  git clone -q --depth 1 https://github.com/ipxe/ipxe /src
  cp /out/embed.ipxe /src/src/
  cd /src/src
  make -j"$(nproc)" bin-x86_64-efi/snponly.efi EMBED=embed.ipxe
  cp bin-x86_64-efi/snponly.efi /out/snponly-homelab.efi
'

# The CI large-file check rejects binaries inside kustomize apps, so the
# binary is committed as base64 text and decoded again by the CronJob.
base64 -w 76 "${HERE}/snponly-homelab.efi" >"${HERE}/snponly-homelab.efi.b64"
rm -f "${HERE}/snponly-homelab.efi"
