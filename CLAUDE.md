# Claude Instructions

Use `AGENTS.md` as the canonical contributor and agent guide for this repository.

Before making changes, read [AGENTS.md](./AGENTS.md) and follow its guidance for project structure, k3s bootstrap, Ansible usage, Argo CD change flow, validation, commits, pull requests, and security practices.

Key rule: Ansible is only for initial k3s cluster installation and base configuration. After Argo CD is installed, all application and infrastructure changes must be made through Git and reconciled by Argo CD.
