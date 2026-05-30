#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"
LITELLM_SECRET_NAME="${LITELLM_SECRET_NAME:-litellm-runtime-secrets}"
LITELLM_OIDC_CLIENT_ID="${LITELLM_OIDC_CLIENT_ID:-litellm}"
AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
AUTHENTIK_SECRET_NAME="${AUTHENTIK_SECRET_NAME:-authentik-secrets}"

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
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local value

  value="$(kubectl -n "${namespace}" get secret "${secret_name}" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}" | decode_base64
}

random_key() {
  printf 'sk-%s' "$(openssl rand -hex 32)"
}

patch_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local value="$4"
  local encoded_value

  encoded_value="$(printf '%s' "${value}" | base64 | tr -d '\n')"
  kubectl -n "${namespace}" patch secret "${secret_name}" \
    --type merge \
    --patch "{\"data\":{\"${key}\":\"${encoded_value}\"}}" >/dev/null
}

kubectl get namespace "${LITELLM_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${LITELLM_NAMESPACE}" >/dev/null
kubectl label namespace "${LITELLM_NAMESPACE}" \
  app.kubernetes.io/managed-by=argocd \
  home-lab.rboiko.com/gateway-scope=public \
  --overwrite >/dev/null

if ! kubectl -n "${AUTHENTIK_NAMESPACE}" get secret "${AUTHENTIK_SECRET_NAME}" >/dev/null 2>&1; then
  printf 'Authentik secret %s/%s does not exist. Run scripts/create-authentik-secret.sh first.\n' \
    "${AUTHENTIK_NAMESPACE}" "${AUTHENTIK_SECRET_NAME}" >&2
  exit 1
fi

litellm_master_key="$(secret_key_value "${LITELLM_NAMESPACE}" "${LITELLM_SECRET_NAME}" LITELLM_MASTER_KEY || random_key)"
litellm_salt_key="$(secret_key_value "${LITELLM_NAMESPACE}" "${LITELLM_SECRET_NAME}" LITELLM_SALT_KEY || random_key)"
litellm_oidc_client_secret="$(secret_key_value "${AUTHENTIK_NAMESPACE}" "${AUTHENTIK_SECRET_NAME}" LITELLM_OIDC_CLIENT_SECRET || random_key)"

patch_secret_key "${AUTHENTIK_NAMESPACE}" "${AUTHENTIK_SECRET_NAME}" LITELLM_OIDC_CLIENT_ID "${LITELLM_OIDC_CLIENT_ID}"
patch_secret_key "${AUTHENTIK_NAMESPACE}" "${AUTHENTIK_SECRET_NAME}" LITELLM_OIDC_CLIENT_SECRET "${litellm_oidc_client_secret}"

kubectl -n "${LITELLM_NAMESPACE}" create secret generic "${LITELLM_SECRET_NAME}" \
  --from-literal=LITELLM_MASTER_KEY="${litellm_master_key}" \
  --from-literal=LITELLM_SALT_KEY="${litellm_salt_key}" \
  --from-literal=GENERIC_CLIENT_ID="${LITELLM_OIDC_CLIENT_ID}" \
  --from-literal=GENERIC_CLIENT_SECRET="${litellm_oidc_client_secret}" \
  --dry-run=client \
  -o yaml | kubectl apply -f - >/dev/null

printf 'Created or updated %s/%s without printing secret values.\n' "${LITELLM_NAMESPACE}" "${LITELLM_SECRET_NAME}"
printf 'Synced LiteLLM OIDC client secret into %s/%s.\n' "${AUTHENTIK_NAMESPACE}" "${AUTHENTIK_SECRET_NAME}"
