# Update Strategy

This cluster separates operating system updates from Kubernetes upgrades.

## Raspberry Pi OS Packages

Ansible installs and enables `unattended-upgrades` during bootstrap. Keep package policy in Ansible because it is host-level configuration, but do not use Ansible for normal application or platform changes after Argo CD is running.

`kured` watches for `/var/run/reboot-required` and reboots one node at a time. The maintenance window is Saturday `03:00-04:00` Europe/Berlin, before k3s upgrade jobs are allowed to run.

## k3s Upgrades

Rancher `system-upgrade-controller` is installed by Argo CD. The k3s server and agent upgrade `Plan` objects are also managed by Argo CD under:

```text
clusters/lab/gitops/platform/system-upgrade-controller/plans/
```

The plans use `concurrency: 1`, drain nodes before upgrade, upgrade control-plane nodes first, and only then upgrade agents. The version is pinned to `v1.35.4+k3s1`; do not use a floating channel in this lab.

To upgrade k3s:

1. Read the k3s release notes and confirm Cilium, Longhorn, cert-manager, and Gateway API compatibility.
2. Update `k3s_version` in `ansible/group_vars/all.yml`.
3. Update both k3s `Plan` versions in `clusters/lab/gitops/platform/system-upgrade-controller/plans/k3s-upgrade-plans.yaml`.
4. Update the `SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE` patch in `clusters/lab/gitops/platform/system-upgrade-controller/system-upgrade-controller-application.yaml`.
5. Open a pull request and validate with `kubectl kustomize clusters/lab/gitops` and `kubectl kustomize clusters/lab/gitops/platform/system-upgrade-controller/plans`.
6. Merge during the planned maintenance window and monitor `kubectl -n system-upgrade get plans,jobs`.

Use Ansible again only for rebuilds, node replacement, or bootstrap recovery.

## Platform Component Updates

Renovate runs from GitHub Actions every Monday before 06:00 Europe/Berlin. It opens pull requests for Argo CD Helm chart pins, Git tag pins, GitHub Actions, and the pinned Argo CD upstream install URL.

Configure a repository secret named `RENOVATE_TOKEN` before enabling the workflow. Use a token that can create branches and pull requests; include `workflow` scope if Renovate should update files under `.github/workflows/`.

Renovate intentionally does not merge cluster updates by itself. Review the release notes, wait for CI, merge the PR, and let Argo CD reconcile the change from Git.

The k3s version, k3s upgrade Plans, and `rancher/kubectl` helper image remain manual because they must stay coordinated.
