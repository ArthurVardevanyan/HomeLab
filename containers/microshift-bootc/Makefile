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
#   make iso            Create a bootable ISO from the image
#   make clean          Clean up build artifacts and temp clone
#
# Variables:
#   USHIFT_GITREF       Git ref/branch/tag (default: main)
#   BOOTC_IMAGE_TAG     Base image SHA override (auto-fetched if unset)
#   IMAGE_TAG           Image tag (auto-detected from version.txt if empty)
#   ISO_OUTPUT_DIR      Output directory for ISO (default: ./output)
#   PUSH_REGISTRY       Registry host (default: registry.arthurvardevanyan.com)
#   PUSH_ORG            Registry org (default: homelab)
#   BUILD_MODE          RPM source: "local" (build), "copr", or "release"
#
# Build Modes:
#   BUILD_MODE=local  (default) Builds RPMs from source using `make rpm`
#                     Takes 15-20 minutes (Go compilation required)
#   BUILD_MODE=copr   Downloads pre-built RPMs from COPR repository
#                     Takes ~2 minutes (no compilation required)
#   BUILD_MODE=release Downloads pre-built RPMs from GitHub releases
#                     Takes ~2 minutes (pre-built, no compilation, fastest download)
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

# --- Build mode (local, copr, or release) ---
BUILD_MODE ?= local

# --- Internal ---
CLONE_DIR      ?= /tmp/microshift-$(shell echo $(USHIFT_GITREF) | tr '/-' '__')
ASSETS_TMP_DIR ?= /tmp/microshift-assets-$(shell echo $(USHIFT_GITREF) | tr '/-' '__')
SHA_CACHE_FILE ?= $(shell pwd)/stream10.sha
ISO_OUTPUT_DIR ?= $(shell pwd)/output
OKD_VERSION_TAG ?= $(shell test -f "$(CLONE_DIR)/src/okd/get_version.sh" && "$(CLONE_DIR)/src/okd/get_version.sh" latest-amd64 2>/dev/null || echo "")

# --- Derived image name ---
IMAGE_NAME = $(PUSH_REGISTRY)/$(PUSH_ORG)/microshift-bootc

.PHONY: _clone _clone-assets _ensure-sha fetch-sha srpm rpm rpm-copr image push iso clean

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
		echo "Using pre-built RPMs from COPR..."; \
		$(MAKE) -f "$(CLONE_DIR)/Makefile" rpm-copr || { echo "ERROR: COPR RPMs not available for this architecture"; exit 1; }; \
	elif [ "$(BUILD_MODE)" = "release" ]; then \
		echo "Using pre-built RPMs from GitHub releases..."; \
		$(MAKE) rpm-release; \
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
# NOTE: The current "copr" target actually downloads from GitHub releases,
# which is the fastest option. COPR downloads are slower due to additional
# infrastructure overhead.
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

# Alias: rpm-release is the preferred name for downloading from GitHub releases
.PHONY: rpm-release
rpm-release: rpm-copr

# ==============================================================================
# RPM download from GitHub releases (direct download - fastest option)
# ==============================================================================
rpm-release: _clone
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

# ==============================================================================
# BootC image build (using custom Containerfile with baked-in configs)
# ==============================================================================
image: rpm
	@echo "Building BootC image using custom Containerfile..."
	@BOOTC_IMAGE_TAG="$(BOOTC_IMAGE_TAG)" \
		BUILD_MODE="$(BUILD_MODE)" \
		COCKPIT="${COCKPIT:-0}" \
		Domain="${DOMAIN:-microshift.dc2.vardevanyan.com}" \
		PODMAN_OPTS="${PODMAN_OPTS:--no-cache}" \
		podman build -f "$(shell pwd)/bootc.Containerfile" \
		--build-arg BUILD_MODE="$(BUILD_MODE)" \
		--build-arg COCKPIT="${COCKPIT:-0}" \
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
push: image
	@if [ -z "$(IMAGE_TAG)" ]; then \
		echo "Auto-detected version from $(_version_file): $(_image_version)"; \
	fi
	@IMAGE_REF="$(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))"; \
	echo "Pushing '$$IMAGE_REF' to $(PUSH_REGISTRY)/$(PUSH_ORG)/..." ; \
	podman tag "localhost/microshift-bootc:latest" "$$IMAGE_REF" ; \
	podman push "$$IMAGE_REF"
# ==============================================================================
# Create a bootable ISO from the built image
# ==============================================================================
iso: image
	@mkdir -p "$(ISO_OUTPUT_DIR)"
	@IMAGE_REF="$(IMAGE_NAME):$(if $(IMAGE_TAG),$(IMAGE_TAG),$(_image_version))" ; \
	if [ -z "$(IMAGE_TAG)" ]; then echo "Auto-detected version from $(_version_file): $(_image_version)"; fi ; \
	echo "Creating bootable ISO from image '$$IMAGE_REF'..." ; \
	echo "  [1/4] Pulling image locally..." ; \
	if ! podman inspect "$$IMAGE_REF" >/dev/null 2>&1; then \
		podman pull "$$IMAGE_REF" ; \
	fi ; \
	\
	echo "  [2/4] Creating temporary rootfs..." ; \
	TEMP_ROOTFS=$$(mktemp -d /tmp/microshift-iso-XXXXXX) ; \
	podman create --name microshift-iso-tmp "$$IMAGE_REF" ; \
	podman export microshift-iso-tmp | tar -C "$$TEMP_ROOTFS" -x ; \
	podman rm microshift-iso-tmp ; \
	\
	echo "  [3/4] Preparing ISO contents..." ; \
	ISO_DIR=$(ISO_OUTPUT_DIR) ; \
	mkdir -p "$$ISO_DIR"/{efi,isolinux} ; \
	\
	echo "    Extracting kernel..." ; \
	kernel_dir="$$TEMP_ROOTFS/usr/lib/modules" ; \
	for kf in $$(find $$kernel_dir -name 'vmlinuz*' 2>/dev/null | head -1); do \
		kernel_name=$$(basename "$$kf") ; \
		cp "$$kf" "$$ISO_DIR/efi/vmlinuz" ; \
		echo "    Kernel: $$kf" ; \
	done ; \
	\
	for it in $$(find $$TEMP_ROOTFS/usr/lib/modules -name 'initramfs*' 2>/dev/null | head -1); do \
		init_name=$$(basename "$$it") ; \
		cp "$$it" "$$ISO_DIR/efi/initrd.img" ; \
		echo "    Initramfs: $$it" ; \
	done ; \
	\
	if [ ! -f "$$ISO_DIR/efi/vmlinuz" ] || [ ! -f "$$ISO_DIR/efi/initrd.img" ]; then \
		echo "ERROR: Kernel or initramfs not found in image!" ; \
		rm -rf "$$TEMP_ROOTFS" ; \
		exit 1 ; \
	fi ; \
	\
	echo "    Extracting bootc bootloader..." ; \
	cp /usr/share/grub/contents/grub.cfg "$$ISO_DIR/grub.cfg" 2>/dev/null || \
		echo "menuentry 'MicroShift BootC' { \\\n\tlinux /efi/vmlinuz root=/dev/sr0 \\\n\tinitrd /efi/initrd.img \n}" > "$$ISO_DIR/grub.cfg" ; \
	\
	echo "    Creating bootable ISO image..." ; \
	grub2-mkrescue -o "$$ISO_DIR/microshift.iso" -c "$$ISO_DIR/grub.cfg" -b isolinux/isolinux.bin -eltorito-alt-boot "$$"ISO_DIR/ 2>/dev/null || \
	grub2-mkrescue -o "$$ISO_DIR/microshift.iso" "$$ISO_DIR/" 2>/dev/null || \
	{ \
		echo "  [4/4] Fallback: creating basic ISO with grub2-mkrescue..." ; \
		grub2-mkrescue -o "$$ISO_DIR/microshift.iso" "$$ISO_DIR/" 2>/dev/null 
	} ; \
	\
	rm -rf "$$TEMP_ROOTFS" ; \
	\
	echo "" ; \
	echo "ISO created: $$ISO_DIR/microshift.iso"

# ==============================================================================
# Cleanup
# ==============================================================================
clean:
	rm -rf "$(CLONE_DIR)"
	rm -rf "$(ISO_OUTPUT_DIR)"
