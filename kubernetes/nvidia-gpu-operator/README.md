# Nvidia GPU Operator

## Build Driver Image

```bash
podman build -f kubernetes/nvidia-gpu-operator/Containerfile -t registry.arthurvardevanyan.com/homelab/nvidia/driver:580.95.05-6.12.0-142.el10.x86_64-centos10 . && podman push registry.arthurvardevanyan.com/homelab/nvidia/driver:580.95.05-6.12.0-142.el10.x86_64-centos10
```

## Ref

- <https://github.com/Markus-feu/okd-nvidia-driver>
