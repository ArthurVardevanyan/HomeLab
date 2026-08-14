TAG ?= $(shell date -u +%Y.%m.%d.%H%M%S)
EXPIRE ?= 26w
WORKSPACE_RESULTS_PATH ?= /tmp/image
IMG ?= registry.arthurvardevanyan.com/homelab/llama-swap-metrics-exporter:$(TAG)
export KO_DOCKER_REPO=$(shell echo $(IMG) | cut -d: -f1)
# Use Red Hat's lightweight static image as the ko base
# Check latest: skopeo inspect --raw docker://registry.access.redhat.com/hi/static:latest | skopeo manifest-digest /dev/stdin
export KO_DEFAULTBASEIMAGE=registry.access.redhat.com/hi/static@sha256:4c1752f4eabb162d15e26f84909725a3ef516f5753211fcb6ad7d76e6fd519e5
# Skip VCS stamping: ko's underlying `go build` defaults to -buildvcs=true
# (Go 1.18+), which shells out to git and fails hard (exit 128) whenever
# the checkout's ownership doesn't match the running user - exactly the
# case in the Tekton pipeline pod, where git-clone and the ko-build step
# can run as different arbitrary UIDs ("detected dubious ownership").
# No VCS info is needed baked into this minimal binary anyway.
export GOFLAGS=-buildvcs=false

.PHONY: ko-build
ko-build:
	ko build ./cmd/llama-swap-metrics-exporter --bare --sbom none \
	  --image-label quay.expires-after="${EXPIRE}" --tags "${TAG}"

.PHONY: ko-build-pipeline
ko-build-pipeline:
	ko build ./cmd/llama-swap-metrics-exporter --bare --sbom none \
	  --image-label quay.expires-after="${EXPIRE}" --tags "${TAG}"
	echo "${KO_DOCKER_REPO}:${TAG}" > "${WORKSPACE_RESULTS_PATH}"
