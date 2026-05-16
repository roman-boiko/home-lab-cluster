# Repository Guidelines

## Project Structure & Module Organization

This repository manages a home-lab Kubernetes cluster running on k3s. Group code by concern:

- `ansible/`: bootstrap playbooks and inventory for installing and configuring the initial k3s cluster.
- `clusters/`: environment-specific cluster definitions, for example `clusters/prod/` or `clusters/lab/`.
- `apps/`: application manifests, Helm values, or Kustomize overlays.
- `infra/`: shared infrastructure modules such as networking, storage, ingress, and certificates.
- `scripts/`: repeatable helper scripts for bootstrap, validation, and maintenance.
- `docs/`: architecture notes and runbooks.

Avoid committing generated files, local machine artifacts, or secrets.

## Architecture & Change Flow

Use Ansible only for initial cluster installation and base k3s configuration, including Cilium bootstrap networking. After Argo CD is installed, all application and infrastructure changes must be made through Git and reconciled by Argo CD. Avoid direct `kubectl apply`, manual Helm installs, or ad hoc node changes except for recovery.

## Build, Test, and Development Commands

No project-specific build system exists yet. Recommended baseline commands:

- `git status --short`: inspect pending changes.
- `scripts/bootstrap-cluster.sh --check`: preview bootstrap or k3s configuration changes.
- `kubectl diff -k apps/<name>/overlays/<env>`: preview Kubernetes manifest changes when Kustomize overlays are added.
- `helm lint charts/<chart>`: validate Helm charts.
- `argocd app diff <app-name>`: compare Git state with the live cluster.
- `yamllint .`: lint YAML files.

Prefer scripts in `scripts/` for repeatable multi-step operations.

## Coding Style & Naming Conventions

Use two-space indentation for YAML. Use lowercase, hyphen-separated names for directories, Kubernetes resources, and files, for example `apps/external-dns/values-lab.yaml`. Keep manifests declarative and environment overrides isolated under the relevant environment directory.

Shell scripts should use `#!/usr/bin/env bash`, `set -euo pipefail`, and clear variable names.

## Testing Guidelines

Validate infrastructure before opening a pull request. For Ansible changes, run syntax checks and check mode. For post-bootstrap changes, validate rendered manifests and use Argo CD diff where possible. Name validation scripts by purpose, for example `scripts/validate-yaml.sh`.

When CI is added, require formatting, linting, and manifest rendering.

## Commit & Pull Request Guidelines

This repository has no commit history yet, so use concise, imperative commit messages such as `Add external-dns manifests`.

Pull requests should include a short description, affected cluster or app, validation commands run, and operational impact. Link related issues when available.

## Security & Configuration Tips

Do not commit kubeconfigs, tokens, private keys, decrypted secrets, or local state files. Prefer sealed or encrypted secret workflows and document restore steps in `docs/`.
