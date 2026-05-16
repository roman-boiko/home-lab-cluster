#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT_DIR}/clusters/lab/gitops/platform/cert-manager/config/cloudflare-api-token.sealedsecret.yaml"
KUSTOMIZATION="${ROOT_DIR}/clusters/lab/gitops/platform/cert-manager/config/kustomization.yaml"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  printf 'CLOUDFLARE_API_TOKEN is required.\n' >&2
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

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-name sealed-secrets-controller \
      --controller-namespace sealed-secrets \
      --format yaml \
  > "${OUTPUT}"

if ! grep -q 'cloudflare-api-token.sealedsecret.yaml' "${KUSTOMIZATION}"; then
  printf '  - cloudflare-api-token.sealedsecret.yaml\n' >> "${KUSTOMIZATION}"
fi

printf 'Wrote %s\n' "${OUTPUT}"
printf 'Updated %s\n' "${KUSTOMIZATION}"
