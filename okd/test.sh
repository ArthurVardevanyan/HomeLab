#!/bin/bash

export EXEMPTIONS=(
  "check=kubeconform,file=install-config.yaml"
  "check=kubeconform,file=vm-config.yaml"
  "check=kubeconform,file=node-config/gpu-1.yaml"
  "check=kubeconform,file=node-config/worker-1.yaml"
  "check=kubeconform,file=node-config/worker-2.yaml"
  "check=kubeconform,file=node-config/worker-3.yaml"
  "check=kubeconform,file=sandbox/kubevirt/okd/configs/install-config.yaml"
  "check=unresolved-placeholder,file=install-config.yaml"
)
