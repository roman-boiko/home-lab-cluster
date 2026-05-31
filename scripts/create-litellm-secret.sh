#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
NAMESPACE="${LITELLM_NAMESPACE:-litellm}"
SECRET_NAME="${LITELLM_SECRET_NAME:-litellm-runtime-secrets}"

export KUBECONFIG="${KUBECONFIG_PATH}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd openssl

decode_base64() {
  if base64 --help 2>/dev/null | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

secret_key_value() {
  local key="$1"
  local value

  value="$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}" | decode_base64
}

random_key() {
  printf 'sk-%s' "$(openssl rand -hex 32)"
}

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}" >/dev/null
kubectl label namespace "${NAMESPACE}" \
  app.kubernetes.io/managed-by=argocd \
  home-lab.rboiko.com/gateway-scope=private \
  --overwrite >/dev/null

master_key="$(secret_key_value LITELLM_MASTER_KEY || random_key)"
salt_key="$(secret_key_value LITELLM_SALT_KEY || random_key)"

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=LITELLM_MASTER_KEY="${master_key}" \
  --from-literal=LITELLM_SALT_KEY="${salt_key}" \
  --dry-run=client \
  -o yaml | kubectl apply -f - >/dev/null

printf 'Created or updated %s/%s without printing secret values.\n' "${NAMESPACE}" "${SECRET_NAME}"
