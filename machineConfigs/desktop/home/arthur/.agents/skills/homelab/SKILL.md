---
name: homelab
description: Operational conventions for the HomeLab repository. Activates for any task that interacts with this repo's OKD or MicroShift clusters, applies manifests, or modifies cluster state.
---

# HomeLab Skill

The authoritative content lives in the HomeLab repository at:

`~/Projects/Code/homelab/SKILL.md`

Load that file (and the companion `~/Projects/Code/homelab/AGENTS.md`) before
acting on any HomeLab cluster, manifest, or Ansible task. If the workspace
is `~/Projects/Code/homelab`, prefer the in-repo copy at
`~/Projects/Code/homelab/.agents/skills/homelab/SKILL.md`.
