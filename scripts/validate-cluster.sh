#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
INVENTORY="${ANSIBLE_INVENTORY:-${ROOT_DIR}/ansible/inventory/hosts.ini}"
EXPECTED_NODES="${EXPECTED_NODES:-4}"
ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"

export KUBECONFIG="${KUBECONFIG_PATH}"
export ANSIBLE_LOCAL_TEMP

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

info() {
  printf 'INFO: %s\n' "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

kubectl_wait() {
  kubectl "$@" >/dev/null
}

require_cmd kubectl
require_cmd ansible

[[ -f "${KUBECONFIG_PATH}" ]] || fail "Kubeconfig not found at ${KUBECONFIG_PATH}. Run scripts/bootstrap-cluster.sh first."
[[ -f "${INVENTORY}" ]] || fail "Ansible inventory not found at ${INVENTORY}."
mkdir -p "${ANSIBLE_LOCAL_TEMP}"

info "Using kubeconfig: ${KUBECONFIG_PATH}"
info "Using inventory: ${INVENTORY}"

kubectl version --client >/dev/null
pass "kubectl is available"

kubectl_wait cluster-info
pass "Kubernetes API is reachable"

actual_nodes="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
[[ "${actual_nodes}" == "${EXPECTED_NODES}" ]] || fail "Expected ${EXPECTED_NODES} nodes, found ${actual_nodes}"
pass "Expected node count is ${EXPECTED_NODES}"

not_ready_nodes="$(kubectl get nodes --no-headers | awk '$2 !~ /Ready/ {print $1}')"
[[ -z "${not_ready_nodes}" ]] || fail "Not all nodes are Ready: ${not_ready_nodes}"
pass "All nodes are Ready"

kubectl_wait -n kube-system rollout status daemonset/cilium --timeout=300s
pass "Cilium daemonset is rolled out"

kubectl_wait -n kube-system rollout status deployment/cilium-operator --timeout=300s
pass "Cilium operator is rolled out"

kubectl_wait get ciliumloadbalancerippool home-lab-lb-pool
pass "Cilium LoadBalancer IP pool exists"

kubectl_wait get ciliuml2announcementpolicy home-lab-l2-announcements
pass "Cilium L2 announcement policy exists"

kubectl_wait get gatewayclass cilium
pass "Cilium GatewayClass exists"

kubectl_wait -n gateway-system get secret home-lab-gateway-tls
pass "Gateway TLS secret exists"

kubectl_wait -n gateway-system get gateway public-https
pass "HTTPS Gateway exists"

gateway_ports="$(kubectl -n gateway-system get gateway public-https -o jsonpath='{range .spec.listeners[*]}{.port}{" "}{end}')"
grep -q '443' <<< "${gateway_ports}" || fail "Gateway does not expose HTTPS port 443"
grep -q '80' <<< "${gateway_ports}" || fail "Gateway does not expose HTTP port 80 for redirects"
pass "Gateway exposes HTTPS and HTTP redirect listener ports"

gateway_protocols="$(kubectl -n gateway-system get gateway public-https -o jsonpath='{range .spec.listeners[*]}{.protocol}{" "}{end}')"
grep -q 'HTTPS' <<< "${gateway_protocols}" || fail "Gateway has no HTTPS listener"
grep -q 'HTTP' <<< "${gateway_protocols}" || fail "Gateway has no HTTP redirect listener"
pass "Gateway listener protocols include HTTPS and HTTP redirect"

kubectl_wait -n gateway-system get httproute http-to-https-redirect
pass "HTTP to HTTPS redirect route exists"

redirect_scheme="$(kubectl -n gateway-system get httproute http-to-https-redirect -o jsonpath='{.spec.rules[0].filters[0].requestRedirect.scheme}')"
[[ "${redirect_scheme}" == "https" ]] || fail "Redirect route scheme is ${redirect_scheme}, expected https"
pass "HTTP redirect route targets HTTPS"

redirect_status="$(kubectl -n gateway-system get httproute http-to-https-redirect -o jsonpath='{.spec.rules[0].filters[0].requestRedirect.statusCode}')"
[[ "${redirect_status}" == "301" ]] || fail "Redirect route status is ${redirect_status}, expected 301"
pass "HTTP redirect route uses 301"

cilium_config="$(kubectl -n kube-system exec ds/cilium -- cilium-dbg config --all)"
grep -q 'EnableL2Announcements[[:space:]]*: true' <<< "${cilium_config}"
pass "Cilium L2 announcements are enabled"

cilium_status="$(kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose)"
grep -q 'KubeProxyReplacement:[[:space:]]*True' <<< "${cilium_status}"
pass "Cilium kube-proxy replacement is enabled"

if command -v cilium >/dev/null 2>&1; then
  cilium status --wait --wait-duration 5m >/dev/null
  pass "Cilium status is healthy"
else
  info "Cilium CLI not found locally; skipped cilium status check"
fi

if kubectl -n kube-system get daemonset kube-flannel-ds >/dev/null 2>&1; then
  fail "Flannel daemonset exists; k3s should be installed with flannel-backend=none"
fi
pass "Flannel is not installed"

if kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^svclb-'; then
  fail "ServiceLB pods exist; servicelb should be disabled"
fi
pass "ServiceLB pods are absent"

if kubectl -n kube-system get helmchart traefik >/dev/null 2>&1; then
  fail "k3s Traefik HelmChart exists; traefik should be disabled"
fi
pass "k3s Traefik HelmChart is absent"

ansible -i "${INVENTORY}" k3s_servers -b -m command -a 'grep -q "flannel-backend: none" /etc/rancher/k3s/config.yaml' >/dev/null
pass "k3s server config disables Flannel"

ansible -i "${INVENTORY}" k3s_servers -b -m command -a 'grep -q "disable-network-policy: true" /etc/rancher/k3s/config.yaml' >/dev/null
pass "k3s server config disables built-in network policy"

ansible -i "${INVENTORY}" k3s_servers -b -m shell -a 'grep -A5 "^disable:" /etc/rancher/k3s/config.yaml | grep -q "servicelb"' >/dev/null
pass "k3s server config disables ServiceLB"

ansible -i "${INVENTORY}" k3s_servers -b -m shell -a 'grep -A5 "^disable:" /etc/rancher/k3s/config.yaml | grep -q "traefik"' >/dev/null
pass "k3s server config disables Traefik"

kubectl_wait -n argocd rollout status deployment/argocd-server --timeout=300s
pass "Argo CD server is rolled out"

kubectl_wait -n argocd rollout status deployment/argocd-repo-server --timeout=300s
pass "Argo CD repo server is rolled out"

kubectl_wait -n argocd get application home-lab-cluster
pass "Argo CD root application exists"

root_app_sync_status="$(kubectl -n argocd get application home-lab-cluster -o jsonpath='{.status.sync.status}')"
[[ "${root_app_sync_status}" == "Synced" ]] || fail "Argo CD root application is ${root_app_sync_status:-unknown}, expected Synced"
pass "Argo CD root application is synced"

kubectl_wait get namespace home-lab-system
pass "GitOps-managed home-lab-system namespace exists"

kubectl_wait -n argocd get application cert-manager
pass "cert-manager Argo CD application exists"

kubectl_wait -n argocd get application cert-manager-config
pass "cert-manager config Argo CD application exists"

kubectl_wait -n cert-manager rollout status deployment/cert-manager --timeout=300s
pass "cert-manager controller is rolled out"

kubectl_wait -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
pass "cert-manager webhook is rolled out"

kubectl_wait -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=300s
pass "cert-manager cainjector is rolled out"

kubectl_wait get clusterissuer letsencrypt-prod
pass "Let's Encrypt ClusterIssuer exists"

kubectl_wait -n gateway-system get certificate home-lab-gateway
pass "Gateway wildcard Certificate exists"

certificate_dns_names="$(kubectl -n gateway-system get certificate home-lab-gateway -o jsonpath='{.spec.dnsNames[*]}')"
grep -q '\*.home.rboiko.com' <<< "${certificate_dns_names}" || fail "Gateway certificate does not include wildcard DNS name"
pass "Gateway certificate includes wildcard DNS name"

if kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1; then
  certificate_ready="$(kubectl -n gateway-system get certificate home-lab-gateway -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
  [[ "${certificate_ready}" == "True" ]] || fail "Gateway certificate is not Ready"
  pass "Gateway Let's Encrypt certificate is Ready"
else
  info "Cloudflare API token secret is missing; skipped certificate Ready check"
fi

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'systemctl is-active iscsid' >/dev/null
pass "iscsid is active on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'test -e /usr/sbin/iscsiadm' >/dev/null
pass "open-iscsi tools are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v mount.nfs' >/dev/null
pass "NFS client tools are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v cryptsetup' >/dev/null
pass "cryptsetup is installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v mkfs.ext4' >/dev/null
pass "ext4 utilities are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'systemctl is-enabled unattended-upgrades' >/dev/null
pass "unattended upgrades are enabled on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a '! swapon --show | grep -q .' >/dev/null
pass "swap is disabled on all nodes"

printf '\nCluster validation completed successfully.\n'
