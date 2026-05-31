#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT_DIR}/clusters/lab/gitops/platform/datadog/agent/datadog-secret.sealedsecret.yaml"
KUSTOMIZATION="${ROOT_DIR}/clusters/lab/gitops/platform/datadog/agent/kustomization.yaml"

if [[ -z "${DATADOG_API_KEY:-}" ]]; then
  printf 'DATADOG_API_KEY is required.\n' >&2
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
  printf 'kubectl is required.\n' >&2
  exit 1
}

command -v kubeseal >/dev/null 2>&1 || {
  printf 'kubeseal is required. Install it from the Sealed Secrets release for your platform.\n' >&2
  exit 1
}

kubectl -n datadog create secret generic datadog-secret \
  --from-literal=api-key="${DATADOG_API_KEY}" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-name sealed-secrets-controller \
      --controller-namespace sealed-secrets \
      --format yaml \
  > "${OUTPUT}"

if ! grep -q 'datadog-secret.sealedsecret.yaml' "${KUSTOMIZATION}"; then
  printf '  - datadog-secret.sealedsecret.yaml\n' >> "${KUSTOMIZATION}"
fi

printf 'Wrote %s\n' "${OUTPUT}"
printf 'Updated %s\n' "${KUSTOMIZATION}"
printf 'Commit both files to Git.\n'
