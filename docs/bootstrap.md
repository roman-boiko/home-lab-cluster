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

Edit `ansible/group_vars/all.yml` before the first run. k3s, Cilium, Cilium CLI, and Argo CD bootstrap inputs are pinned for reproducible installs.

The OS preparation role enables Raspberry Pi memory cgroups, disables swap, installs Longhorn host dependencies, enables iSCSI, and configures unattended package updates.

k3s is configured without its bundled networking and ingress components:

```yaml
flannel-backend: none
disable-network-policy: true
disable:
  - servicelb
  - traefik
```

Cilium is installed once during bootstrap before Argo CD because the cluster needs a CNI before GitOps can run. After bootstrap, the `cilium` Argo CD application owns the Helm release and Cilium day-2 configuration from `clusters/lab/gitops/platform/cilium`.

Cilium is configured for bare-metal `LoadBalancer` services with LB IPAM and L2 announcements. The GitOps-managed IP pool is `192.168.5.100-192.168.5.200` on the `192.168.5.0/24` LAN.

Cilium Gateway API is enabled during bootstrap. GitOps manages two Cilium Gateways:

- `gateway-system/public-https` uses `192.168.5.100` for internet-facing services.
- `gateway-system/private-https` uses `192.168.5.101` for LAN-only administrative services.

Both Gateways expose HTTPS on port `443` and expose HTTP on port `80` only for `301` redirects to HTTPS. Public routes must live in namespaces labeled
`home-lab.rboiko.com/gateway-scope=public`; private routes must live in namespaces labeled `home-lab.rboiko.com/gateway-scope=private`.

Only forward router traffic or Cloudflare Tunnel traffic to `192.168.5.100`. Do not forward internet traffic to `192.168.5.101`. Use local DNS for private
names such as `argocd.home.rboiko.com`, `longhorn.home.rboiko.com`, and `hubble.home.rboiko.com` so they resolve to `192.168.5.101` only on the LAN.

Argo CD is exposed only through the private Gateway at `argocd.home.rboiko.com`. The Gateway terminates TLS with the shared wildcard certificate and forwards
plain HTTP to `argocd-server` on port `80`; Argo CD authentication remains enabled.

Longhorn and Hubble UI are also exposed only through the private Gateway:

- `longhorn.home.rboiko.com` routes to `longhorn-system/longhorn-frontend`.
- `hubble.home.rboiko.com` routes to `kube-system/hubble-ui`.

Keep the private names in LAN DNS only and do not forward `192.168.5.101` from the router.

Authentik is exposed through the public Gateway:

- `auth.home.rboiko.com` routes to `authentik/authentik-server`.

Authentik is installed by Argo CD from the official Authentik Helm chart. Its PostgreSQL database is managed separately by CloudNativePG as
`authentik/authentik-postgres` on Longhorn storage; Authentik connects through the `authentik-postgres-rw` service. Before syncing Authentik for the first
time, create the live runtime secret:

```bash
scripts/create-authentik-secret.sh
```

The Authentik server includes the embedded proxy outpost. Use that outpost for initial proxy providers, then add Kubernetes-managed outposts later if separate
outpost deployments are needed for scale or isolation.

CloudNativePG is installed by Argo CD from the official CloudNativePG Helm chart. Use `scripts/migrate-authentik-postgres-to-cnpg.sh` only for the one-time
migration from the old bundled Authentik PostgreSQL StatefulSet to the CloudNativePG cluster.

Longhorn is installed by Argo CD from the Longhorn Helm chart. It creates the `longhorn` StorageClass and marks it as the cluster default. The k3s `local-path` StorageClass is kept available but marked non-default by GitOps. The Longhorn pre-upgrade hook is disabled because Longhorn recommends disabling it for Argo CD and other GitOps installs.

The Gateway TLS Secret is owned by cert-manager through GitOps as `gateway-system/home-lab-gateway-tls` and is used by both Gateways. Ansible does not create temporary TLS material.

cert-manager is installed by Argo CD from the Jetstack Helm chart. The production `ClusterIssuer` uses Let's Encrypt DNS-01 with Cloudflare and requests `home.rboiko.com` plus `*.home.rboiko.com` into the Gateway TLS Secret. The token must exist as `cert-manager/cloudflare-api-token`; manage it with Sealed Secrets or another encrypted GitOps workflow, not a plaintext manifest.

Sealed Secrets is installed by Argo CD from the Bitnami Labs Helm chart. See `docs/secrets.md` for generating the encrypted Cloudflare token manifest.

## 3. Run Bootstrap

Preview the run:

```bash
scripts/bootstrap-cluster.sh --check
```

Apply the bootstrap:

```bash
scripts/bootstrap-cluster.sh
```

Ansible installs k3s first, joins the agent nodes, performs the first Cilium install if Cilium is missing, then applies the pinned Argo CD install overlay from `clusters/lab/bootstrap/argocd/install`. After Argo CD is running, Ansible applies only the seed resources from `clusters/lab/bootstrap/argocd/seed`.

The root Argo CD application is `home-lab-cluster`. It tracks this repository at `clusters/lab/gitops` and automatically reconciles changes from `main`. Child applications then self-manage Argo CD, the AppProject allowlist, Authentik, CloudNativePG, Cilium, cert-manager, Longhorn, and Sealed Secrets after bootstrap.

Argo CD pods include `dnsConfig.options.ndots=1` in the pinned install overlay so public Git hosts such as `github.com` resolve before the home-lab search domain.

The playbook also downloads the kubeconfig to `kubeconfig/lab-k3s.yaml` on the local machine and rewrites the API endpoint to the k3s server IP. This file is ignored by Git because it contains cluster credentials.

## 4. Post-Bootstrap Rule

After Argo CD is installed, do not make routine changes with direct `kubectl apply`, manual Helm installs, or node-local edits. Commit desired state under `clusters/lab/gitops` and let Argo CD reconcile it. Direct cluster changes are only for bootstrap, diagnostics, or recovery.

Use the downloaded kubeconfig for local reads and diagnostics:

```bash
KUBECONFIG=kubeconfig/lab-k3s.yaml kubectl get nodes
```

## 5. Validate Installation

Run the post-install validation script from the repository root:

```bash
scripts/validate-cluster.sh
```

The script checks Kubernetes API access, four Ready nodes, Cilium rollout, disabled k3s Flannel/ServiceLB/Traefik/network-policy components, Argo CD and child applications, Authentik, CloudNativePG, cert-manager, Sealed Secrets, Longhorn rollout and default StorageClass, Longhorn host prerequisites, unattended upgrades, and disabled swap.
