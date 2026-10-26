# syntax=docker/dockerfile-1
# MicroShift BootC Containerfile
#
# Builds a MicroShift BootC image with:
# - All OS-level configs baked in (firewall, sysctl, cockpit)
# - MicroShift enabled as a host systemd service (bootc boots via systemd)
# - UFS kernel modules + initramfs for MinisForum S100
# - Optional Cockpit installation
#
# Build Args:
#   COCKPIT       Enable Cockpit installation (default: 0)
#   DOMAIN        Domain for API server (default: microshift.dc2.vardevanyan.com)
#   BUILD_MODE    RPM source mode: local or release (default: release)
# ==============================================================================

FROM quay.io/centos/centos:stream9-minimal AS builder

ARG BUILD_MODE=release
ARG GH_TOKEN=""
ARG USHIFT_GITREF=main

ENV \
  BUILD_MODE=${BUILD_MODE} \
  GH_TOKEN=${GH_TOKEN} \
  CLONE_DIR=/tmp/microshift-build \
  ASSETS_TMP_DIR=/tmp/microshift-assets \
  LVM_DISK=/var/lib/microshift-okd/lvmdisk.image \
  LVM_VOLSIZE=100G \
  VG_NAME=myvg1 \
  EXTRA_CONFIG=/var/lib/microshift-okd/custom_config.yaml \
  DOMAIN=microshift.dc2.vardevanyan.com \
  API_SERVER_PORT=6443 \
  KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  LAST_IMAGE_FILE=/var/lib/microshift-okd/.last_image \
  COCKPIT=0 \
  USHIFT_GIT_URL=https://github.com/microshift-io/microshift.git \
  OKD_VERSION_TAG=unknown \
  OKD_RELEASE_IMAGE_X86_64="quay.io/okd/scos-release" \
  OKD_RELEASE_IMAGE_AARCH64="ghcr.io/microshift-io/okd/okd-release-arm64" \
  BOOTC_IMAGE_URL=quay.io/centos-bootc/centos-bootc \
  PUSH_REGISTRY=registry.arthurvardevanyan.com \
  PUSH_ORG=homelab \
  WITH_KINDNET=1 \
  WITH_TOPOLVM=1 \
  WITH_OLM=1 \
  WITH_MULTUS=1 \
  EMBED_CONTAINER_IMAGES=0 \
  EMBED_TEST_IMAGE=1

# Install build dependencies
RUN microdnf -y install git tar make gcc go sudo shadow-utils findutils curl && \
  microdnf -y install dnf && \
  microdnf clean all

# Clone upstream repos
RUN mkdir -p "$CLONE_DIR" "$ASSETS_TMP_DIR" && \
  git clone --branch "$USHIFT_GITREF" --single-branch "$USHIFT_GIT_URL" "$CLONE_DIR" && \
  git clone --depth 1 --branch main https://github.com/openshift/microshift.git "$ASSETS_TMP_DIR" && \
  mkdir -p "$CLONE_DIR/assets/release" "$CLONE_DIR/packaging/crio.conf.d" && \
  cp "$ASSETS_TMP_DIR/assets/release/"* "$CLONE_DIR/assets/release/" && \
  cp "$ASSETS_TMP_DIR/packaging/crio.conf.d/"* "$CLONE_DIR/packaging/crio.conf.d/" && \
  rm -rf "$ASSETS_TMP_DIR"

# Download/copy RPMs based on BUILD_MODE (do NOT call upstream Makefile's image target)
RUN if [ "$BUILD_MODE" = "local" ]; then \
      echo "Building RPMs from source (BUILD_MODE=local)..."; \
      USHIFT_GITREF="$USHIFT_GITREF" \
      OKD_VERSION_TAG="$OKD_VERSION_TAG" \
      OKD_RELEASE_IMAGE_X86_64="$OKD_RELEASE_IMAGE_X86_64" \
      OKD_RELEASE_IMAGE_AARCH64="$OKD_RELEASE_IMAGE_AARCH64" \
      BOOTC_IMAGE_URL="$BOOTC_IMAGE_URL" \
      BOOTC_IMAGE_TAG="$BOOTC_IMAGE_TAG" \
      WITH_KINDNET="$WITH_KINDNET" \
      WITH_TOPOLVM="$WITH_TOPOLVM" \
      WITH_OLM="$WITH_OLM" \
      WITH_MULTUS="$WITH_MULTUS" \
      EMBED_CONTAINER_IMAGES="$EMBED_CONTAINER_IMAGES" \
      EMBED_TEST_IMAGE="$EMBED_TEST_IMAGE" \
      make -f "$CLONE_DIR/Makefile" rpm; \
    elif [ "$BUILD_MODE" = "release" ]; then \
      echo "Downloading pre-built RPMs from GitHub releases..."; \
      mkdir -p "$CLONE_DIR/_output/rpmbuild/RPMS/" && \
      TEMP_DIR=$(mktemp -d) && \
      curl -fsSL --retry 3 -L "https://github.com/microshift-io/microshift/releases/latest/download/microshift-rpms-$(uname -m).tgz" -o "$TEMP_DIR/rpms.tgz" && \
      tar -xzf "$TEMP_DIR/rpms.tgz" -C "$TEMP_DIR/" && \
      find "$TEMP_DIR" -name "*.rpm" -exec mv {} "$CLONE_DIR/_output/rpmbuild/RPMS/" \; && \
      VERSION=$(curl -fsSL --max-time 10 "https://api.github.com/repos/microshift-io/microshift/releases/latest" | grep '"tag_name"' | head -1 | awk -F'"' '{print $$4}') && \
      if [ -n "$VERSION" ]; then \
        echo "$VERSION" > "$CLONE_DIR/_output/rpmbuild/RPMS/version.txt"; \
      else \
        echo "unknown" > "$CLONE_DIR/_output/rpmbuild/RPMS/version.txt"; \
      fi && \
      rm -rf "$TEMP_DIR"; \
    elif [ "$BUILD_MODE" = "copr" ]; then \
      echo "ERROR: BUILD_MODE=copr is not supported. Use BUILD_MODE=release instead."; \
      exit 1; \
    fi; \
    echo "RPMs are ready in $CLONE_DIR/_output/rpmbuild/RPMS/"

# ==============================================================================
# Final image
# ==============================================================================
FROM quay.io/centos-bootc/centos-bootc:stream10 AS os-base

# Update the OS (and therefore the kernel) once, here, so the UFS modules built
# in the next stage always match the kernel that ships in the final image.
RUN dnf -y update && dnf clean all && rm -rf /var/cache/*

# ==============================================================================
# UFS modules (MinisForum S100). The CentOS Stream 10 kernel ships without
# CONFIG_SCSI_UFSHCD, so build ufshcd-{core,pci,pltfrm} against its exact version.
# Set WITH_UFS=0 to skip.
# ==============================================================================
FROM os-base AS ufs-builder
ARG WITH_UFS=1
ENV WITH_UFS=${WITH_UFS}
COPY build-ufs-modules.sh /usr/local/bin/build-ufs-modules.sh
RUN /usr/local/bin/build-ufs-modules.sh

# ==============================================================================
# Final image
# ==============================================================================
FROM os-base

LABEL org.opencontainers.image.source="https://github.com/ArthurVardevanyan/HomeLab" \
  org.opencontainers.image.title="MicroShift BootC" \
  org.opencontainers.image.description="MicroShift BootC image with baked-in OS configs and MicroShift enabled as a systemd service" \
  org.opencontainers.image.licenses="Apache-2.0"

ARG DOMAIN=microshift.dc2.vardevanyan.com
ARG COCKPIT=0
ARG WITH_KINDNET=1
ARG WITH_TOPOLVM=1
ARG WITH_OLM=1
ARG WITH_MULTUS=1

ENV \
  CONTAINER_NAME=microshift-okd \
  LVM_DISK=/var/lib/microshift-okd/lvmdisk.image \
  LVM_VOLSIZE=100G \
  VG_NAME=myvg1 \
  EXTRA_CONFIG=/var/lib/microshift-okd/custom_config.yaml \
  DOMAIN=${DOMAIN} \
  API_SERVER_PORT=6443 \
  KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  LAST_IMAGE_FILE=/var/lib/microshift-okd/.last_image \
  COCKPIT=${COCKPIT} \
  WITH_KINDNET=${WITH_KINDNET} \
  WITH_TOPOLVM=${WITH_TOPOLVM} \
  WITH_OLM=${WITH_OLM} \
  WITH_MULTUS=${WITH_MULTUS} \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Copy scripts
COPY setup-lvm.sh /usr/local/bin/setup-lvm.sh
COPY postinstall-custom.sh /usr/local/bin/postinstall-custom.sh

# Copy SSH public keys for root SSH access (injected at build time for CI,
# or from .ssh-keys/authorized_keys generated by the Makefile for local builds)
COPY .ssh-keys/authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys

# Copy RPMs from builder stage (do NOT use upstream create_repos.sh — it has version detection bugs)
COPY --from=builder /tmp/microshift-build/_output/rpmbuild/RPMS/ /tmp/microshift-rpms/

# Install required packages and MicroShift with dependencies
RUN \
  # Import EPEL GPG key and install EPEL repo
  rpm --import https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9 && \
  rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
  # Install createrepo_c and ca-certificates for repo creation
  dnf install -y createrepo_c ca-certificates && \
  # Create local MicroShift repo and index it
  echo "[microshift-local]" > /etc/yum.repos.d/microshift-local.repo && \
  echo "name=MicroShift Local Repository" >> /etc/yum.repos.d/microshift-local.repo && \
  echo "baseurl=file:///tmp/microshift-rpms" >> /etc/yum.repos.d/microshift-local.repo && \
  echo "enabled=1" >> /etc/yum.repos.d/microshift-local.repo && \
  echo "gpgcheck=0" >> /etc/yum.repos.d/microshift-local.repo && \
  createrepo /tmp/microshift-rpms && \
  # Detect MicroShift major.minor version from RPM filename - write to file to avoid variable issues
  for f in /tmp/microshift-rpms/microshift-4*.rpm; do basename "$f" | cut -d- -f2 | cut -d. -f1,2 > /tmp/ms-ver.txt; break; done && \
  MS_VER=$(cat /tmp/ms-ver.txt) && \
  echo "Detected MicroShift version: ${MS_VER}" && \
  echo "[openshift-mirror-beta]" > /etc/yum.repos.d/microshift-deps.repo && \
  echo "name=OpenShift Mirror Beta Repository" >> /etc/yum.repos.d/microshift-deps.repo && \
  echo "baseurl=https://mirror.openshift.com/pub/openshift-v4/dependencies/rpms/${MS_VER}-el9-beta/" >> /etc/yum.repos.d/microshift-deps.repo && \
  echo "enabled=1" >> /etc/yum.repos.d/microshift-deps.repo && \
  echo "gpgcheck=0" >> /etc/yum.repos.d/microshift-deps.repo && \
  # Install MicroShift and its OpenShift dependencies from the configured repos
  dnf install -y \
    microshift \
    microshift-release-info \
    cri-o \
    cri-tools \
    openshift-clients \
    openvswitch3.4 && \
  # Cleanup
  rm -rf /tmp/microshift-rpms && \
  rm -f /etc/yum.repos.d/microshift-local.repo /etc/yum.repos.d/microshift-deps.repo && \
  dnf clean all && rm -rf /var/cache/* && \
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# Install Kindnet CNI
RUN if [ "${WITH_KINDNET}" = "1" ]; then dnf install -y microshift-networking; fi

# Install TopoLVM storage if enabled (disabled - package not in repos)
# RUN if [ "${WITH_TOPOLVM}" = "1" ]; then dnf install -y microshift-topolvm microshift-topolvm-release-info; fi

# Install OLM operator lifecycle manager if enabled (disabled - package not in repos)
# RUN if [ "${WITH_OLM}" = "1" ]; then dnf install -y microshift-olm microshift-olm-release-info; fi

# Install Multus CNI if enabled (disabled - package not in repos)
# RUN if [ "${WITH_MULTUS}" = "1" ]; then dnf install -y microshift-multus microshift-multus-release-info; fi

# Make scripts executable
RUN chmod +x /usr/local/bin/setup-lvm.sh /usr/local/bin/postinstall-custom.sh

# MicroShift runs on the host as microshift.service (enabled below); this is a
# bootc image booted via systemd, so no ENTRYPOINT/CMD is set. Setting one makes
# `podman run <image> bootc install ...` run the entrypoint instead of bootc.
RUN systemctl enable microshift.service

# Set up LVM directory
RUN mkdir -p /var/lib/microshift-okd

# Set up MicroShift directories
RUN mkdir -p /var/lib/microshift/resources/kubeadmin

# Install the out-of-tree UFS modules (MinisForum S100) and rebuild the initramfs
# so the machine can see its internal UFS disk at boot. Modules are unsigned, so
# Secure Boot must be off. No-op when WITH_UFS=0.
ARG WITH_UFS=1
COPY --from=ufs-builder /out/ /tmp/ufs-out/
RUN set -eux; \
  if [ "${WITH_UFS}" = "1" ]; then \
    KVER=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); \
    [ "$(echo "${KVER}" | wc -l)" -eq 1 ]; \
    [ "$(cat /tmp/ufs-out/kver)" = "${KVER}" ] || { echo "UFS modules were built for a different kernel than the final image"; exit 1; }; \
    mkdir -p "/usr/lib/modules/${KVER}/extra/ufs" /etc/dracut.conf.d; \
    cp /tmp/ufs-out/ufs/*.ko "/usr/lib/modules/${KVER}/extra/ufs/"; \
    depmod -a "${KVER}"; \
    echo 'add_drivers+=" ufshcd-core ufshcd-pci "' > /etc/dracut.conf.d/ufshcd.conf; \
    dracut -vf --no-hostonly "/usr/lib/modules/${KVER}/initramfs.img" "${KVER}"; \
    chmod 0644 "/usr/lib/modules/${KVER}/initramfs.img"; \
    lsinitrd "/usr/lib/modules/${KVER}/initramfs.img" | grep -q 'ufshcd-pci'; \
  fi; \
  rm -rf /tmp/ufs-out
