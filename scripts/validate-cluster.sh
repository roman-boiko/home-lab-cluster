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
