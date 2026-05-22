#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
SECRET_NAME="${AUTHENTIK_SECRET_NAME:-authentik-secrets}"

export KUBECONFIG="${KUBECONFIG_PATH}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd openssl

if kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  printf 'Secret %s/%s already exists; leaving it unchanged.\n' "${NAMESPACE}" "${SECRET_NAME}"
  exit 0
fi

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}" >/dev/null

authentik_secret_key="$(openssl rand -base64 60 | tr -d '\n')"
postgres_password="$(openssl rand -base64 36 | tr -d '\n')"
postgres_admin_password="$(openssl rand -base64 36 | tr -d '\n')"

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=AUTHENTIK_SECRET_KEY="${authentik_secret_key}" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="${postgres_password}" \
  --from-literal=password="${postgres_password}" \
  --from-literal=postgres-password="${postgres_admin_password}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

printf 'Created secret %s/%s without printing secret values.\n' "${NAMESPACE}" "${SECRET_NAME}"
