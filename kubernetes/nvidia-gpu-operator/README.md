# Nvidia GPU Operator

## Node Labels

```bash
kubectl label node gpu-1 node-role.kubernetes.io/gpu=true --overwrite
kubectl taint node gpu-1 node-role.kubernetes.io/gpu:NoSchedule --overwrite
```

## Build Driver Image

```bash
export KERNEL_VERSION="6.12.0-142.el10.x86_64"
export DRIVER_VERSION="580.95.05"
podman build --build-arg KERNEL_VERSION=${KERNEL_VERSION} --build-arg DRIVER_VERSION=${DRIVER_VERSION} -f kubernetes/nvidia-gpu-operator/Containerfile -t registry.arthurvardevanyan.com/homelab/nvidia/driver:${DRIVER_VERSION}-${KERNEL_VERSION}-centos10 . && podman push registry.arthurvardevanyan.com/homelab/nvidia/driver:${DRIVER_VERSION}-${KERNEL_VERSION}-centos10
```

## Ref

- <https://github.com/Markus-feu/okd-nvidia-driver>
