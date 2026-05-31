#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT_DIR}/clusters/lab/gitops/platform/litellm/manifests/provider-keys.sealedsecret.yaml"
KUSTOMIZATION="${ROOT_DIR}/clusters/lab/gitops/platform/litellm/manifests/kustomization.yaml"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -z "${GEMINI_API_KEY:-}" ]]; then
  printf 'At least one of ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY is required.\n' >&2
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

args=()
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && args+=(--from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}")
[[ -n "${OPENAI_API_KEY:-}" ]]    && args+=(--from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}")
[[ -n "${GEMINI_API_KEY:-}" ]]    && args+=(--from-literal=GEMINI_API_KEY="${GEMINI_API_KEY}")
[[ -n "${OLLAMA_API_BASE:-}" ]]   && args+=(--from-literal=OLLAMA_API_BASE="${OLLAMA_API_BASE}")

kubectl -n litellm create secret generic litellm-provider-keys \
  "${args[@]}" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-name sealed-secrets-controller \
      --controller-namespace sealed-secrets \
      --format yaml \
  > "${OUTPUT}"

if ! grep -q 'provider-keys.sealedsecret.yaml' "${KUSTOMIZATION}"; then
  printf '  - provider-keys.sealedsecret.yaml\n' >> "${KUSTOMIZATION}"
fi

printf 'Wrote %s\n' "${OUTPUT}"
printf 'Updated %s\n' "${KUSTOMIZATION}"
printf 'Commit both files to Git.\n'
