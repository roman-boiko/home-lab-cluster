# Cluster Bootstrap

This repository bootstraps one k3s server and three k3s agents on Raspberry Pi OS.

## 1. Prepare Inventory

Edit `ansible/inventory/hosts.ini` and replace the example IP addresses and SSH user:

```ini
[k3s_servers]
pi-1 ansible_host=192.168.1.101 ansible_user=pi

[k3s_agents]
pi-2 ansible_host=192.168.1.102 ansible_user=pi
pi-3 ansible_host=192.168.1.103 ansible_user=pi
pi-4 ansible_host=192.168.1.104 ansible_user=pi
```

## 2. Review Defaults

Edit `ansible/group_vars/all.yml` before the first run. Pin `k3s_version` for reproducible installs if required.

The OS preparation role enables Raspberry Pi memory cgroups, disables swap, installs Longhorn host dependencies, enables iSCSI, and configures unattended package updates.

k3s is configured without its bundled networking and ingress components:

```yaml
flannel-backend: none
disable-network-policy: true
disable:
  - servicelb
  - traefik
```

Cilium is installed during bootstrap before Argo CD. Pin `cilium_version` and `cilium_cli_version` in `ansible/group_vars/all.yml` for reproducible installs.

## 3. Run Bootstrap

Preview the run:

```bash
scripts/bootstrap-cluster.sh --check
```

Apply the bootstrap:

```bash
scripts/bootstrap-cluster.sh
```

Ansible installs k3s first, joins the agent nodes, installs Cilium networking, then installs Argo CD as the final bootstrap step.

The playbook also downloads the kubeconfig to `kubeconfig/lab-k3s.yaml` on the local machine and rewrites the API endpoint to the k3s server IP. This file is ignored by Git because it contains cluster credentials.

## 4. Post-Bootstrap Rule

After Argo CD is installed, do not make routine changes with direct `kubectl apply`, manual Helm installs, or node-local edits. Commit desired state to Git and let Argo CD reconcile it.

Use the downloaded kubeconfig for local reads and diagnostics:

```bash
KUBECONFIG=kubeconfig/lab-k3s.yaml kubectl get nodes
```

## 5. Validate Installation

Run the post-install validation script from the repository root:

```bash
scripts/validate-cluster.sh
```

The script checks Kubernetes API access, four Ready nodes, Cilium rollout, disabled k3s Flannel/ServiceLB/Traefik/network-policy components, Argo CD rollout, Longhorn host prerequisites, unattended upgrades, and disabled swap.
