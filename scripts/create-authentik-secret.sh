#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
SECRET_NAME="${AUTHENTIK_SECRET_NAME:-authentik-secrets}"
POSTGRES_HOST="${AUTHENTIK_POSTGRES_HOST:-authentik-postgres-rw}"
POSTGRES_NAME="${AUTHENTIK_POSTGRES_NAME:-authentik}"
POSTGRES_USER="${AUTHENTIK_POSTGRES_USER:-authentik}"
POSTGRES_PORT="${AUTHENTIK_POSTGRES_PORT:-5432}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_OIDC_SECRET_NAME="${ARGOCD_OIDC_SECRET_NAME:-authentik-oidc}"
ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID:-argocd}"

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

patch_secret_key() {
  local key="$1"
  local value="$2"
  local encoded_value

  encoded_value="$(printf '%s' "${value}" | base64 | tr -d '\n')"
  kubectl -n "${NAMESPACE}" patch secret "${SECRET_NAME}" \
    --type merge \
    --patch "{\"data\":{\"${key}\":\"${encoded_value}\"}}" >/dev/null
}

sync_argocd_oidc_secret() {
  local client_secret="$1"

  kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || return 0
  kubectl -n "${ARGOCD_NAMESPACE}" create secret generic "${ARGOCD_OIDC_SECRET_NAME}" \
    --from-literal=clientSecret="${client_secret}" \
    --dry-run=client \
    -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" label secret "${ARGOCD_OIDC_SECRET_NAME}" \
    app.kubernetes.io/part-of=argocd \
    --overwrite >/dev/null
}

if kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  argocd_oidc_client_secret="$(secret_key_value ARGOCD_OIDC_CLIENT_SECRET || openssl rand -base64 36 | tr -d '\n')"
  patch_secret_key AUTHENTIK_POSTGRESQL__HOST "${POSTGRES_HOST}"
  patch_secret_key AUTHENTIK_POSTGRESQL__NAME "${POSTGRES_NAME}"
  patch_secret_key AUTHENTIK_POSTGRESQL__USER "${POSTGRES_USER}"
  patch_secret_key AUTHENTIK_POSTGRESQL__PORT "${POSTGRES_PORT}"
  patch_secret_key ARGOCD_OIDC_CLIENT_ID "${ARGOCD_OIDC_CLIENT_ID}"
  patch_secret_key ARGOCD_OIDC_CLIENT_SECRET "${argocd_oidc_client_secret}"
  patch_secret_key username "${POSTGRES_USER}"
  sync_argocd_oidc_secret "${argocd_oidc_client_secret}"
  printf 'Updated non-secret PostgreSQL settings in %s/%s without rotating credentials.\n' "${NAMESPACE}" "${SECRET_NAME}"
  printf 'Synced Argo CD OIDC client secret to %s/%s without printing secret values.\n' "${ARGOCD_NAMESPACE}" "${ARGOCD_OIDC_SECRET_NAME}"
  exit 0
fi

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}" >/dev/null

authentik_secret_key="$(openssl rand -base64 60 | tr -d '\n')"
postgres_password="$(openssl rand -base64 36 | tr -d '\n')"
postgres_admin_password="$(openssl rand -base64 36 | tr -d '\n')"
argocd_oidc_client_secret="$(openssl rand -base64 36 | tr -d '\n')"

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=AUTHENTIK_SECRET_KEY="${authentik_secret_key}" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST="${POSTGRES_HOST}" \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME="${POSTGRES_NAME}" \
  --from-literal=AUTHENTIK_POSTGRESQL__USER="${POSTGRES_USER}" \
  --from-literal=AUTHENTIK_POSTGRESQL__PORT="${POSTGRES_PORT}" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="${postgres_password}" \
  --from-literal=ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID}" \
  --from-literal=ARGOCD_OIDC_CLIENT_SECRET="${argocd_oidc_client_secret}" \
  --from-literal=username="${POSTGRES_USER}" \
  --from-literal=password="${postgres_password}" \
  --from-literal=postgres-password="${postgres_admin_password}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

sync_argocd_oidc_secret "${argocd_oidc_client_secret}"

printf 'Created secret %s/%s without printing secret values.\n' "${NAMESPACE}" "${SECRET_NAME}"
printf 'Synced Argo CD OIDC client secret to %s/%s without printing secret values.\n' "${ARGOCD_NAMESPACE}" "${ARGOCD_OIDC_SECRET_NAME}"
