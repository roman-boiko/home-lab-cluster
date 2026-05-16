# Repository Guidelines

## Project Structure & Module Organization

This repository manages a Raspberry Pi home-lab Kubernetes cluster running k3s. Keep files grouped by lifecycle:

- `ansible/`: Raspberry Pi OS preparation, k3s install, first Cilium install, Argo CD seed, and kubeconfig fetch.
- `clusters/lab/bootstrap/argocd/install/`: pinned Argo CD install overlay, including DNS `ndots=1` patches.
- `clusters/lab/bootstrap/argocd/seed/`: one-time AppProject and root Application applied by Ansible.
- `clusters/lab/gitops/`: Argo CD root tree reconciled from Git.
- `clusters/lab/gitops/platform/`: platform components managed by Argo CD: `argocd`, `cert-manager`, `cilium`, `gateway`, `longhorn`, and `sealed-secrets`.
- `scripts/`: repeatable helper scripts for bootstrap, validation, and maintenance.
- `docs/`: runbooks, including bootstrap and encrypted secret workflows.

Avoid committing generated files, local machine artifacts, or secrets.

## Architecture & Change Flow

Use Ansible only for bootstrap: OS preparation, initial k3s installation, first Cilium networking install, kubeconfig download, pinned Argo CD install, and the root Argo CD seed. After Argo CD is running, manage all platform and application changes through Git under `clusters/lab/gitops`.

The root app is `home-lab-cluster`. Child apps self-manage Argo CD, Cilium, cert-manager, Longhorn, Sealed Secrets, and the shared Gateway. Avoid direct `kubectl apply`, manual Helm installs, and node-local edits except for diagnostics or recovery.

## Build, Test, and Development Commands

Recommended baseline commands:

- `git status --short`: inspect pending changes.
- `scripts/bootstrap-cluster.sh --check`: preview bootstrap or k3s configuration changes.
- `kubectl kustomize clusters/lab/gitops`: render the Argo CD root tree.
- `kubectl kustomize clusters/lab/bootstrap/argocd/seed`: render bootstrap seed manifests.
- `kubectl kustomize clusters/lab/bootstrap/argocd/install`: render the pinned Argo CD install overlay.
- `argocd app diff <app-name>`: compare Git state with the live cluster.
- `scripts/validate-cluster.sh`: validate the live cluster after bootstrap or sync.
- `yamllint .`: lint YAML files.

Prefer scripts in `scripts/` for repeatable multi-step operations.

## Coding Style & Naming Conventions

Use two-space indentation for YAML. Use lowercase, hyphen-separated names for directories, Kubernetes resources, and files, for example `clusters/lab/gitops/platform/cert-manager`. Keep manifests declarative and keep lab-specific state under `clusters/lab/`.

Shell scripts should use `#!/usr/bin/env bash`, `set -euo pipefail`, and clear variable names.

## Testing Guidelines

Validate infrastructure before opening a pull request. For Ansible changes, run syntax checks and check mode where safe. For GitOps changes, render the affected Kustomize tree and use Argo CD diff where possible.

GitHub Actions is the CI platform. The current workflow lints YAML, checks Ansible syntax, and renders the Argo CD bootstrap/install and root GitOps Kustomize trees.

## Commit & Pull Request Guidelines

Use concise, imperative commit messages such as `Add external-dns manifests`.

Pull requests should include a short description, affected cluster or app, validation commands run, and operational impact. Link related issues when available.

## Security & Configuration Tips

Do not commit kubeconfigs, tokens, private keys, decrypted secrets, or local state files. Runtime secrets should use Sealed Secrets or another encrypted GitOps workflow. Use `scripts/seal-cloudflare-token.sh` to generate the encrypted `cert-manager/cloudflare-api-token` manifest from `CLOUDFLARE_API_TOKEN`; see `docs/secrets.md`.
