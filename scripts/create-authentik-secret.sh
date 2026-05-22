#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
SECRET_NAME="${AUTHENTIK_SECRET_NAME:-authentik-secrets}"
POSTGRES_HOST="${AUTHENTIK_POSTGRES_HOST:-authentik-postgresql}"
POSTGRES_NAME="${AUTHENTIK_POSTGRES_NAME:-authentik}"
POSTGRES_USER="${AUTHENTIK_POSTGRES_USER:-authentik}"
POSTGRES_PORT="${AUTHENTIK_POSTGRES_PORT:-5432}"

export KUBECONFIG="${KUBECONFIG_PATH}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd openssl

patch_secret_key() {
  local key="$1"
  local value="$2"
  local encoded_value

  encoded_value="$(printf '%s' "${value}" | base64 | tr -d '\n')"
  kubectl -n "${NAMESPACE}" patch secret "${SECRET_NAME}" \
    --type merge \
    --patch "{\"data\":{\"${key}\":\"${encoded_value}\"}}" >/dev/null
}

if kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  patch_secret_key AUTHENTIK_POSTGRESQL__HOST "${POSTGRES_HOST}"
  patch_secret_key AUTHENTIK_POSTGRESQL__NAME "${POSTGRES_NAME}"
  patch_secret_key AUTHENTIK_POSTGRESQL__USER "${POSTGRES_USER}"
  patch_secret_key AUTHENTIK_POSTGRESQL__PORT "${POSTGRES_PORT}"
  printf 'Updated non-secret PostgreSQL settings in %s/%s without rotating credentials.\n' "${NAMESPACE}" "${SECRET_NAME}"
  exit 0
fi

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}" >/dev/null

authentik_secret_key="$(openssl rand -base64 60 | tr -d '\n')"
postgres_password="$(openssl rand -base64 36 | tr -d '\n')"
postgres_admin_password="$(openssl rand -base64 36 | tr -d '\n')"

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=AUTHENTIK_SECRET_KEY="${authentik_secret_key}" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST="${POSTGRES_HOST}" \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME="${POSTGRES_NAME}" \
  --from-literal=AUTHENTIK_POSTGRESQL__USER="${POSTGRES_USER}" \
  --from-literal=AUTHENTIK_POSTGRESQL__PORT="${POSTGRES_PORT}" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="${postgres_password}" \
  --from-literal=password="${postgres_password}" \
  --from-literal=postgres-password="${postgres_admin_password}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

printf 'Created secret %s/%s without printing secret values.\n' "${NAMESPACE}" "${SECRET_NAME}"
