# ==============================================================================
# MicroShift BootC Image Builder
# ==============================================================================
# Wrapper that clones upstream into /tmp, fetches the latest stream10 SHA,
# and delegates to the upstream Makefile (srpm -> rpm -> image).
#
# Targets:
#   make fetch-sha      Fetch latest stream10 SHA from quay.io (caches locally)
#   make srpm           Build SRPMs (clones upstream repo if needed)
#   make rpm            Build RPMs (depends on srpm)
#   make rpm-copr       Download pre-built RPMs from COPR
#   make rpm-release    Download pre-built RPMs from GitHub releases (fastest)
#   make image          Build BootC image (depends on rpm)
#   make push           Push image to registry
#   make iso            Build Anaconda-installer ISO using bootc-image-builder
#   make install-live   Print bootc install command for a Fedora Live USB (UFS hardware)
#   make clean          Clean up build artifacts and temp clone
#
# Variables:
#   USHIFT_GITREF       Git ref/branch/tag (default: main)
#   BOOTC_IMAGE_TAG     Base image SHA override (auto-fetched if unset)
#   IMAGE_TAG           Image tag (auto-detected from version.txt if empty)
#   ISO_OUTPUT_DIR      Output directory for ISO (default: ./output)
#   PUSH_REGISTRY       Registry host (default: registry.arthurvardevanyan.com)
#   PUSH_ORG            Registry org (default: homelab)
#   BUILD_MODE          RPM source: "local" (build) or "release" (pre-built)
#   WITH_UFS            1 (default) builds UFS modules + initramfs for MinisForum S100; 0 skips
#   INSTALL_DISK        Target disk printed by install-live (default: /dev/sda)
#   STORE_SIZE          tmpfs size for container storage in install-live (default: 6G)
#
# Build Modes:
#   BUILD_MODE=local  (default) Builds RPMs from source using `make rpm`
#                     Takes 15-20 minutes (Go compilation required)
#   BUILD_MODE=release Downloads pre-built RPMs from GitHub releases
#                     Takes ~2 minutes (pre-built, no compilation, fastest)
#
# All modes produce RPMs in: _output/rpmbuild/RPMS/
# ==============================================================================

# --- Upstream repo configuration ---
USHIFT_GIT_URL ?= https://github.com/microshift-io/microshift.git
USHIFT_GITREF   ?= main

# --- Base image (stream10) ---
BOOTC_IMAGE_URL ?= quay.io/centos-bootc/centos-bootc
BOOTC_IMAGE_TAG ?= sha256-$(shell cat $(SHA_CACHE_FILE) 2>/dev/null || echo "")

# --- Component flags ---
WITH_KINDNET   ?= 1
WITH_TOPOLVM   ?= 1
WITH_OLM       ?= 1
WITH_MULTUS    ?= 1
EMBED_CONTAINER_IMAGES ?= 0
EMBED_TEST_IMAGE  ?= 1

# --- Registry ---
PUSH_REGISTRY ?= registry.arthurvardevanyan.com
PUSH_ORG      ?= homelab
IMAGE_TAG     ?=
IMAGE_SUFFIX  ?= $(shell date +%Y-%m-%d_%H%M%S)

# --- Build mode (local, copr, or release) ---
BUILD_MODE ?= local

# --- Internal ---
CLONE_DIR      ?= /tmp/microshift-$(shell echo $(USHIFT_GITREF) | tr '/-' '__')
ASSETS_TMP_DIR ?= /tmp/microshift-assets-$(shell echo $(USHIFT_GITREF) | tr '/-' '__')
SHA_CACHE_FILE ?= $(shell pwd)/stream10.sha
ISO_OUTPUT_DIR ?= $(shell pwd)/output
BIB_OUT        ?= $(ISO_OUTPUT_DIR)/bib-out
OKD_VERSION_TAG ?= $(shell test -f "$(CLONE_DIR)/src/okd/get_version.sh" && "$(CLONE_DIR)/src/okd/get_version.sh" latest-amd64 2>/dev/null || echo "")

# --- Derived image name ---
IMAGE_NAME = $(PUSH_REGISTRY)/$(PUSH_ORG)/microshift-bootc

BIB_IMAGE ?= quay.io/centos-bootc/bootc-image-builder:latest

.PHONY: _clone _clone-assets _ensure-sha fetch-sha srpm rpm rpm-copr image push iso install-live clean

# SSH keys (collect user's ~/.ssh/*.pub for root SSH access on booted node)
SSH_KEY_FILE ?= $(shell pwd)/.ssh-keys/authorized_keys
$(SSH_KEY_FILE):
	@mkdir -p $(shell dirname "$@")
	@if ls ~/.ssh/*.pub 2>/dev/null; then cat ~/.ssh/*.pub | sort -u > "$@"; else touch "$@"; fi

# ==============================================================================
# SHA auto-fetch: query quay.io API for the latest stream10 SHA
# ==============================================================================
$(SHA_CACHE_FILE):
	@mkdir -p "$(shell dirname "$@")"
	@bash "$(shell pwd)/fetch-sha.py" > "$@"
	@echo "Cached SHA: $$(cat $@)"

fetch-sha: | $(SHA_CACHE_FILE)
	@echo "Latest stream10 SHA: $$(cat $(SHA_CACHE_FILE))"

# Ensure SHA is cached before any build
_ensure-sha: | $(SHA_CACHE_FILE)
	@if [ -z "$$BOOTC_IMAGE_TAG" ]; then \
		export BOOTC_IMAGE_TAG="sha256-$$(cat $(SHA_CACHE_FILE))"; \
	fi

# ==============================================================================
# Clone upstream repo
# ==============================================================================
_clone: _ensure-sha
	@test -d "$(CLONE_DIR)" || git clone --branch "$(USHIFT_GITREF)" --single-branch "$(USHIFT_GIT_URL)" "$(CLONE_DIR)"

_clone-assets: _clone
	@if [ ! -d "$(ASSETS_TMP_DIR)" ]; then \
		git clone --depth 1 --branch main https://github.com/openshift/microshift.git "$(ASSETS_TMP_DIR)"; \
	fi
	@mkdir -p "$(CLONE_DIR)/assets/release"
	@if [ -z "$$(ls $(CLONE_DIR)/assets/release/ 2>/dev/null)" ]; then \
		cp "$(ASSETS_TMP_DIR)/assets/release/"* "$(CLONE_DIR)/assets/release/"; \
	fi
	@mkdir -p "$(CLONE_DIR)/packaging/crio.conf.d"
	@if [ -z "$$(ls $(CLONE_DIR)/packaging/crio.conf.d/ 2>/dev/null)" ]; then \
		cp "$(ASSETS_TMP_DIR)/packaging/crio.conf.d/"* "$(CLONE_DIR)/packaging/crio.conf.d/"; \
	fi

# ==============================================================================
# SRPM build (delegates to upstream Makefile)
# ==============================================================================
srpm: _clone-assets
	@cd "$(CLONE_DIR)" && \
		USHIFT_GITREF="$(USHIFT_GITREF)" \
		OKD_VERSION_TAG="$(if $(OKD_VERSION_TAG),$(OKD_VERSION_TAG),unknown)" \
		OKD_RELEASE_IMAGE_X86_64="quay.io/okd/scos-release" \
		OKD_RELEASE_IMAGE_AARCH64="ghcr.io/microshift-io/okd/okd-release-arm64" \
		$(MAKE) -f "$(CLONE_DIR)/Makefile" srpm

# ==============================================================================
# RPM build (delegates to upstream Makefile or COPR)
# ==============================================================================
rpm: _clone
	@if [ "$(BUILD_MODE)" = "copr" ]; then \
		echo "ERROR: BUILD_MODE=copr has been removed. Use BUILD_MODE=release instead."; \
		exit 1; \
	elif [ "$(BUILD_MODE)" = "release" ]; then \
		echo "Using pre-built RPMs from GitHub releases..."; \
		$(MAKE) rpm-copr; \
	else \
		echo "Building RPMs from source (BUILD_MODE=local)..."; \
		cd "$(CLONE_DIR)" && \
			USHIFT_GITREF="$(USHIFT_GITREF)" \
			OKD_VERSION_TAG="$(if $(OKD_VERSION_TAG),$(OKD_VERSION_TAG),unknown)" \
			OKD_RELEASE_IMAGE_X86_64="quay.io/okd/scos-release" \
			OKD_RELEASE_IMAGE_AARCH64="ghcr.io/microshift-io/okd/okd-release-arm64" \
			BOOTC_IMAGE_URL="$(BOOTC_IMAGE_URL)" \
			BOOTC_IMAGE_TAG="$(BOOTC_IMAGE_TAG)" \
			WITH_KINDNET="$(WITH_KINDNET)" \
			WITH_TOPOLVM="$(WITH_TOPOLVM)" \
			WITH_OLM="$(WITH_OLM)" \
			WITH_MULTUS="$(WITH_MULTUS)" \
			EMBED_CONTAINER_IMAGES="$(EMBED_CONTAINER_IMAGES)" \
			EMBED_TEST_IMAGE="$(EMBED_TEST_IMAGE)" \
			$(MAKE) -f "$(CLONE_DIR)/Makefile" rpm; \
		fi

# ==============================================================================
# COPR/Release RPMs download
# ==============================================================================
# ==============================================================================
# RPM download from GitHub releases (fastest option)
# ==============================================================================
rpm-copr: _clone
	@echo "Downloading pre-built RPMs from GitHub releases..." ; \
	mkdir -p "$(CLONE_DIR)/_output/rpmbuild/RPMS/" ; \
	TEMP_DIR=$$(mktemp -d) ; \
	curl -fsSL --retry 3 -L "https://github.com/microshift-io/microshift/releases/latest/download/microshift-rpms-$(shell uname -m).tgz" -o "$${TEMP_DIR}/rpms.tgz" ; \
	tar -xzf "$${TEMP_DIR}/rpms.tgz" -C "$${TEMP_DIR}/" ; \
	find "$${TEMP_DIR}" -name "*.rpm" -exec mv {} "$(CLONE_DIR)/_output/rpmbuild/RPMS/" \; ; \
	find "$(CLONE_DIR)/_output/rpmbuild/RPMS/" -type d -empty -not -path "$(CLONE_DIR)/_output/rpmbuild/RPMS/" -exec rmdir {} \; 2>/dev/null || true ; \
	VERSION=$$(curl -fsSL --max-time 10 "https://api.github.com/repos/microshift-io/microshift/releases/latest" | grep '"tag_name"' | head -1 | awk -F'"' '{print $$4}'); \
	if [ -n "$${VERSION}" ]; then \
		echo "$${VERSION}" > "$(CLONE_DIR)/_output/rpmbuild/RPMS/version.txt"; \
		echo "Pre-built RPMs downloaded successfully (version: $$VERSION)"; \
	else \
		echo "WARNING: Could not determine version from GitHub API"; \
		echo "unknown" > "$(CLONE_DIR)/_output/rpmbuild/RPMS/version.txt"; \
	fi ; \
	rm -rf "$${TEMP_DIR}"

# Alias: rpm-release is a pure alias for rpm-copr (no recipe, just depends on it)
.PHONY: rpm-release
rpm-release: rpm-copr

# ==============================================================================
# BootC image build (using custom Containerfile with baked-in configs)
# ==============================================================================
image: $(SSH_KEY_FILE) rpm
	@test -f $(SSH_KEY_FILE) || touch $(SSH_KEY_FILE)
	@echo "Building BootC image using custom Containerfile..."
	@BOOTC_IMAGE_TAG="$(BOOTC_IMAGE_TAG)" \
		BUILD_MODE="$(BUILD_MODE)" \
		COCKPIT="${COCKPIT:-0}" \
		Domain="${DOMAIN:-microshift.dc2.vardevanyan.com}" \
		PODMAN_OPTS="${PODMAN_OPTS:--no-cache}" \
		podman build -f "$(shell pwd)/bootc.Containerfile" \
		--build-arg BUILD_MODE="$(BUILD_MODE)" \
		--build-arg COCKPIT="${COCKPIT:-0}" \
		--build-arg WITH_UFS="${WITH_UFS:-1}" \
		--build-arg Domain="${DOMAIN:-microshift.dc2.vardevanyan.com}" \
		$(PODMAN_OPTS) \
		-t "microshift-bootc:$(BOOTC_IMAGE_TAG)" \
		-t "localhost/microshift-bootc:latest" \
		.
	@echo "BootC image built successfully."

# ==============================================================================
# Auto-detect version from version.txt (upstream versioning scheme)
# ==============================================================================
_version_file = $(CLONE_DIR)/_output/rpmbuild/RPMS/version.txt
_image_version = $(shell cat $(_version_file) 2>/dev/null | tr '-' '_' || echo "")

# ==============================================================================
# Push image to registry
# ==============================================================================
# IMAGE_SUFFIX: Datetime suffix appended to pushed image tag (default: yyyy-MM-dd_HHmmss)
# Use IMAGE_SUFFIX="" to disable suffix
# ==============================================================================
push: image
	@if [ -z "$(IMAGE_TAG)" ]; then \
		echo "Auto-detected version from $(_version_file): $(_image_version)"; \
	fi
	@IMAGE_REF="$(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))"; \
	if [ -n "$(IMAGE_SUFFIX)" ]; then \
		IMAGE_REF="$$IMAGE_REF-$(IMAGE_SUFFIX)"; \
	fi ; \
	PLAIN_REF="$(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))"; \
	echo "Pushing plain '$$PLAIN_REF' (+ suffixed '$$IMAGE_REF') to $(PUSH_REGISTRY)/$(PUSH_ORG)/..." ; \
	podman tag "localhost/microshift-bootc:latest" "$$PLAIN_REF" ; \
	podman push "$$PLAIN_REF" ; \
	if [ -n "$(IMAGE_SUFFIX)" ]; then \
		podman tag "localhost/microshift-bootc:latest" "$$IMAGE_REF" ; \
		podman push "$$IMAGE_REF" ; \
	fi
# ==============================================================================
# Create a bootable Anaconda-installer ISO using bootc-image-builder
# ==============================================================================
#
# Produces an Anaconda-installer ISO:
#   1. Burns to USB → boot → Anaconda installer → install to disk → reboot
#   2. Embedded MicroShift bootc image (self-upgrading via `bootc upgrade`)
#
# Boot flow:
#   Burn ISO → boot USB → Anaconda text installer → follow prompts →
#   install to disk → reboot → persistent MicroShift node
#
# Variables:
#   BIB_IMAGE     bootc-image-builder container (default: latest)
#   BIB_OUT       temporary build dir inside ISO_OUTPUT_DIR
#   PUSH_REGISTRY / PUSH_ORG / IMAGE_TAG / IMAGE_SUFFIX (same as push)
# ==============================================================================
iso: image push
	@mkdir -p "$(BIB_OUT)"
	@echo "Staging image into rootful store..."
	@podman save $(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version)) -o $(ISO_OUTPUT_DIR)/bootc-image.tar
	@sudo podman load -i $(ISO_OUTPUT_DIR)/bootc-image.tar
	@sudo rm -f $(ISO_OUTPUT_DIR)/bootc-image.tar
	@echo "Building ISO with bootc-image-builder..."
	@sudo podman run --rm --privileged --pull=newer \
		-v $(BIB_OUT):/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage:z \
		$(BIB_IMAGE) --type anaconda-iso --output /output \
		$(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))
	@sudo mv $(BIB_OUT)/bootiso/install.iso $(ISO_OUTPUT_DIR)/microshift.iso
	@sudo rm -rf $(BIB_OUT)
	@echo ""
	@echo "=== ISO: $(ISO_OUTPUT_DIR)/microshift.iso ==="
	@echo ""
	@echo "  Burn to USB:"
	@echo "    sudo dd if=$(ISO_OUTPUT_DIR)/microshift.iso of=/dev/sdX bs=4M status=progress oflag=sync"
	@echo ""
	@echo "  Boot flow:"
	@echo "    Burn ISO → boot USB → Anaconda installer → follow prompts →"
	@echo "    install to disk → reboot → persistent MicroShift node"
	@echo ""
	@echo "  Size: 1-2 GB | Build: ~5-30 min (depsolving installer package set)"

# ==============================================================================
# Print install instructions for hardware the CentOS kernel can't see (UFS)
# ==============================================================================
# Run the printed command from a Fedora Live USB (kernel has UFS support).
# INSTALL_DISK defaults to /dev/sda (MinisForum S100 UFS disk).
# ==============================================================================
INSTALL_DISK ?= /dev/sda
STORE_SIZE ?= 6G

install-live:
	@echo "From a Fedora Live USB, run (DESTROYS all data on $(INSTALL_DISK)):"
	@echo ""
	@echo "  # 1. Keep container storage in RAM (the live root is too small for the image)."
	@echo "  #    Must be the default paths so bootc finds the image via the -v mount below."
	@echo "  sudo mkdir -p /var/lib/containers /var/tmp"
	@echo "  sudo mount -t tmpfs -o size=$(STORE_SIZE) tmpfs /var/lib/containers"
	@echo "  sudo mount -t tmpfs -o size=2G tmpfs /var/tmp"
	@echo ""
	@echo "  # 2. Pull the image (as root, so it lands in /var/lib/containers)."
	@echo "  sudo podman pull $(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))"
	@echo ""
	@echo "  # 3. Install to disk."
	@echo "  sudo podman run --rm --privileged --pid=host --entrypoint bootc \\"
	@echo "    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \\"
	@echo "    --security-opt label=type:unconfined_t \\"
	@echo "    $(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version)) \\"
	@echo "    install to-disk --wipe $(INSTALL_DISK)"
	@echo ""
	@echo "The image must be built with WITH_UFS=1 (default) so its initramfs has the UFS modules."
	@echo "See notes/minisforum-s100-ufssupport.md."

# ==============================================================================
# Cleanup
# ==============================================================================
clean:
	rm -rf "$(CLONE_DIR)"
	rm -rf "$(ISO_OUTPUT_DIR)"
