# OpenShift Logging

Cluster logging stack deployed via ArgoCD GitOps.

## Table of Contents

- [OpenShift Logging](#openshift-logging)
  - [Table of Contents](#table-of-contents)
  - [Components](#components)
  - [File Descriptor Limits](#file-descriptor-limits)
  - [Deploy](#deploy)

## Components

- **Base:** Shared resources (namespace, service accounts, RBAC)
- **Overlays:** Cluster-specific configurations (okd, microshift, etc.)

## File Descriptor Limits

The Vector log collector requires elevated file descriptor limits to watch thousands of log files. These limits are configured in:

- [collector-inotify-fix/README.md](../../okd/okd-configuration/components/collector-inotify-fix/README.md)

This component applies:

- TuneD CR for inotify settings (runtime)
- MachineConfigs for CRI-O ulimit and `fs.nr_open` (boot)

## Deploy

The `okd-configuration` ArgoCD application manages this namespace. Changes are synced automatically from `okd/okd-configuration/overlays/<cluster>`.
