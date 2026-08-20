#!/bin/bash

# OKD installer config template — not a Kubernetes manifest
export EXEMPTIONS=(
  "check=kubeconform,file=kubevirt/okd/configs/install-config.yaml"
  "check=unresolved-placeholder,file=kubevirt/okd/configs/install-config.yaml"
)
