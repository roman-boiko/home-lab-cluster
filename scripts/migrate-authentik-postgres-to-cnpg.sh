#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
NAMESPACE="${AUTHENTIK_NAMESPACE:-authentik}"
SECRET_NAME="${AUTHENTIK_SECRET_NAME:-authentik-secrets}"
OLD_STATEFULSET="${OLD_POSTGRES_STATEFULSET:-authentik-postgresql}"
NEW_CLUSTER="${CNPG_CLUSTER:-authentik-postgres}"
DATABASE="${AUTHENTIK_POSTGRES_NAME:-authentik}"
DB_USER="${AUTHENTIK_POSTGRES_USER:-authentik}"
NEW_HOST="${AUTHENTIK_POSTGRES_HOST:-authentik-postgres-rw}"

export KUBECONFIG="${KUBECONFIG_PATH}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

decode_base64() {
  if base64 --help 2>/dev/null | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

secret_value() {
  local key="$1"
  kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" \
    -o "jsonpath={.data.${key}}" | decode_base64
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

wait_for_condition() {
  local description="$1"
  shift

  printf 'Waiting for %s...\n' "${description}"
  "$@"
}

require_cmd kubectl
require_cmd base64
require_cmd mktemp

kubectl -n "${NAMESPACE}" get statefulset "${OLD_STATEFULSET}" >/dev/null
kubectl -n "${NAMESPACE}" get cluster.postgresql.cnpg.io "${NEW_CLUSTER}" >/dev/null

wait_for_condition "CloudNativePG cluster readiness" \
  kubectl -n "${NAMESPACE}" wait \
  --for=condition=Ready "cluster.postgresql.cnpg.io/${NEW_CLUSTER}" \
  --timeout=600s

old_pod="$(kubectl -n "${NAMESPACE}" get pod \
  -l app.kubernetes.io/instance=authentik,app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}')"
new_pod="$(kubectl -n "${NAMESPACE}" get pod \
  -l "cnpg.io/cluster=${NEW_CLUSTER}" \
  -o jsonpath='{.items[0].metadata.name}')"

[[ -n "${old_pod}" ]] || {
  printf 'Could not find bundled Authentik PostgreSQL pod.\n' >&2
  exit 1
}
[[ -n "${new_pod}" ]] || {
  printf 'Could not find CloudNativePG PostgreSQL pod.\n' >&2
  exit 1
}

postgres_password="$(secret_value AUTHENTIK_POSTGRESQL__PASSWORD)"
workdir="$(mktemp -d)"
dump_file="${workdir}/authentik.dump"
trap 'rm -rf "${workdir}"' EXIT

printf 'Temporarily disabling Authentik self-heal and scaling server/worker to zero.\n'
kubectl -n argocd patch application authentik \
  --type json \
  --patch '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" scale deployment/authentik-server --replicas=0
kubectl -n "${NAMESPACE}" scale deployment/authentik-worker --replicas=0
kubectl -n "${NAMESPACE}" rollout status deployment/authentik-server --timeout=300s
kubectl -n "${NAMESPACE}" rollout status deployment/authentik-worker --timeout=300s

printf 'Dumping bundled PostgreSQL database from %s.\n' "${old_pod}"
kubectl -n "${NAMESPACE}" exec "${old_pod}" -c postgresql -- \
  env "PGPASSWORD=${postgres_password}" \
  pg_dump -U "${DB_USER}" -d "${DATABASE}" \
  --format=custom \
  --no-owner \
  --no-privileges > "${dump_file}"

printf 'Restoring database into CloudNativePG pod %s.\n' "${new_pod}"
kubectl -n "${NAMESPACE}" exec -i "${new_pod}" -c postgres -- \
  env "PGPASSWORD=${postgres_password}" \
  pg_restore -U "${DB_USER}" -d "${DATABASE}" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges < "${dump_file}"

patch_secret_key AUTHENTIK_POSTGRESQL__HOST "${NEW_HOST}"
patch_secret_key AUTHENTIK_POSTGRESQL__NAME "${DATABASE}"
patch_secret_key AUTHENTIK_POSTGRESQL__USER "${DB_USER}"
patch_secret_key AUTHENTIK_POSTGRESQL__PORT "5432"
patch_secret_key username "${DB_USER}"

printf 'Migration completed. Push and sync the Authentik cutover manifests before scaling Authentik back up.\n'
