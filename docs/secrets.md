# Encrypted Secrets

Runtime secrets must not be committed as plain Kubernetes `Secret` manifests.

Use Sealed Secrets for GitOps-managed secrets. After the Sealed Secrets
controller is running and `kubeseal` is installed locally, run:

```bash
CLOUDFLARE_API_TOKEN=... scripts/seal-cloudflare-token.sh
```

The script generates this equivalent command:

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-name sealed-secrets-controller \
      --controller-namespace sealed-secrets \
      --format yaml \
  > clusters/lab/gitops/platform/cert-manager/config/cloudflare-api-token.sealedsecret.yaml
```

The script also adds `cloudflare-api-token.sealedsecret.yaml` to
`clusters/lab/gitops/platform/cert-manager/config/kustomization.yaml`. Commit both files.
The encrypted object should create `cert-manager/cloudflare-api-token`, which is
referenced by the `letsencrypt-prod` ClusterIssuer.

## Datadog API Key

Datadog needs an API key before the Datadog Agent can report telemetry. Generate
a sealed secret from a local environment variable:

```bash
DATADOG_API_KEY=... scripts/seal-datadog-token.sh
```

This writes `clusters/lab/gitops/platform/datadog/agent/datadog-secret.sealedsecret.yaml`
and adds it to the Datadog Agent kustomization. Commit both files. Do not commit
the API key in plaintext.

## Authentik Runtime Secret

Authentik needs a stable signing key and PostgreSQL credentials before its Argo CD
application can start. Create the live secret without printing values:

```bash
scripts/create-authentik-secret.sh
```

This creates `authentik/authentik-secrets` with:

- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_POSTGRESQL__HOST`
- `AUTHENTIK_POSTGRESQL__NAME`
- `AUTHENTIK_POSTGRESQL__USER`
- `AUTHENTIK_POSTGRESQL__PORT`
- `AUTHENTIK_POSTGRESQL__PASSWORD`
- `ARGOCD_OIDC_CLIENT_ID`
- `ARGOCD_OIDC_CLIENT_SECRET`
- `username`
- `password`
- `postgres-password`

Do not rotate `AUTHENTIK_SECRET_KEY` after first install unless you intentionally
want to invalidate existing Authentik sessions and generated identifiers.

The same script mirrors the Argo CD OIDC client secret into
`argocd/authentik-oidc` with the label required by Argo CD. Do not commit this
secret in plaintext.

## LiteLLM Secrets

LiteLLM needs two separate secrets.

**Runtime secret** (not committed) — master key and salt key that must not rotate
after virtual keys have been issued:

```bash
scripts/create-litellm-secret.sh
```

This creates `litellm/litellm-runtime-secrets`.

**Provider keys** (sealed, committed) — real provider API keys for Anthropic,
OpenAI, Gemini, and optionally a local Ollama base URL:

```bash
ANTHROPIC_API_KEY=sk-ant-… \
OPENAI_API_KEY=sk-… \
GEMINI_API_KEY=… \
scripts/seal-litellm-provider-keys.sh
```

This writes `clusters/lab/gitops/platform/litellm/manifests/provider-keys.sealedsecret.yaml`
and adds it to the manifests kustomization. Commit both files. Do not commit
either secret in plaintext.
