# LiteLLM

LiteLLM is deployed from GitOps as `platform/litellm` and exposed through the
private Gateway at:

```text
https://llms.home.rboiko.com
```

Only LAN clients can reach this address. It resolves to `192.168.5.101`; do not
forward this address from the router. In-cluster workloads can also reach the proxy
directly at `http://litellm.litellm.svc:4000`.

## Routing

The route is split by path:

- API paths (`/v1`, `/chat`, `/embeddings`, `/models`, `/key`, `/health`) route
  directly to LiteLLM and must be authorized with a LiteLLM virtual key.
- All other paths (`/`) route through Authentik's embedded proxy outpost, which
  authenticates browser sessions before proxying to LiteLLM admin UI.

## Security Model

Real provider API keys live only in the proxy as sealed secrets. Each agentic
application or user receives a **virtual key** (`sk-…`) from the admin UI with:

- An explicit model allowlist (which models the key may call)
- A maximum budget (USD) and optional RPM/TPM rate caps
- Team assignment for spend tracking

Virtual keys are stored in the LiteLLM PostgreSQL database. The database is
managed by CloudNativePG as `litellm/litellm-postgres` on Longhorn storage.

## Prerequisites

Create the runtime secret before syncing the LiteLLM Argo CD application:

```bash
scripts/create-litellm-secret.sh
```

This creates `litellm/litellm-runtime-secrets` with a stable master key and salt
key. Do not rotate these after virtual keys have been issued.

Seal the provider API keys and commit the result:

```bash
ANTHROPIC_API_KEY=sk-ant-… \
OPENAI_API_KEY=sk-… \
GEMINI_API_KEY=… \
scripts/seal-litellm-provider-keys.sh
```

This writes `clusters/lab/gitops/platform/litellm/manifests/provider-keys.sealedsecret.yaml`
and appends it to the manifests kustomization. Commit both files. The `OLLAMA_API_BASE`
variable is optional; set it if routing to a local Ollama endpoint.

## Issuing Virtual Keys

Log in to `https://llms.home.rboiko.com` with your Authentik account. In the admin
UI, go to **Virtual Keys → Create Key** and configure:

- **Models**: restrict to the model names defined in `configmap.yaml` (e.g.
  `claude-sonnet-4`, `gpt-4o`).
- **Max Budget**: set a USD ceiling to cap provider spend per agent.
- **Rate Limits**: set RPM/TPM caps to prevent runaway agents.

Give each agentic application its own key. Never reuse the master key in
application code.

## Local (Ollama) Provider

Uncomment the `ollama/llama3` entry in
`clusters/lab/gitops/platform/litellm/manifests/configmap.yaml` and set
`OLLAMA_API_BASE` when sealing provider keys:

```bash
OLLAMA_API_BASE=http://192.168.1.x:11434 \
scripts/seal-litellm-provider-keys.sh
```
