---
name: kubernetes-skill
description: Production-grade Kubernetes guidance (KubeShark). Activates for any task involving Kubernetes manifests, Helm charts, Kustomize overlays, RBAC, NetworkPolicies, or cluster operations. Enforces a failure-mode workflow with Conditional Reference Retrieval.
---

# KubeShark (Kubernetes Skill)

This is a stub. The full skill content lives at:

`~/Projects/Code/kubernetes-skill/`

## Activation

Load the upstream workflow before responding to Kubernetes tasks:

1. Read `~/Projects/Code/kubernetes-skill/SKILL.md` for the failure-mode
   workflow.
2. Pull individual files from `~/Projects/Code/kubernetes-skill/references/`
   on demand per the Conditional Reference Retrieval (CRR) pattern. Do not
   preload the full reference set.
3. For platform-specific work (EKS, GKE, AKS, OpenShift, GitOps controllers,
   observability stacks), load the matching file from
   `~/Projects/Code/kubernetes-skill/references/conditional/`.

## Setup

If the local path is missing, clone it first:

```sh
git clone https://github.com/LukasNiessen/kubernetes-skill.git \
    ~/Projects/Code/kubernetes-skill
```
