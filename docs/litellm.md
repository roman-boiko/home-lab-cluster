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

All paths route directly to LiteLLM:

- API paths (`/v1`, `/chat`, `/embeddings`, ...) are authorized with a LiteLLM
  virtual key.
- The admin UI is protected by LiteLLM-native OIDC single sign-on against
  Authentik (the `/sso/callback` flow). There is no proxy outpost in front of
  LiteLLM — running one would intercept the OIDC callback.

## Single Sign-On

LiteLLM authenticates UI users via Authentik OIDC. The Authentik `LiteLLM`
OAuth2 provider issues a `litellm_role` claim derived from group membership:

- Members of `Home Lab Admins` get `proxy_admin` (full admin).
- Everyone else gets `internal_user`.

The required redirect URI in Authentik is
`https://llms.home.rboiko.com/sso/callback`.

LiteLLM's browser-facing authorization request goes to the external
`auth.home.rboiko.com`, while the server-to-server token and userinfo calls use
the in-cluster `authentik-server.authentik.svc` service so the namespace
`CiliumNetworkPolicy` egress covers them.

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

This creates `litellm/litellm-runtime-secrets` with a stable master key, salt
key, and the Authentik OIDC client credentials (`GENERIC_CLIENT_ID` /
`GENERIC_CLIENT_SECRET`), and mirrors the matching `LITELLM_OIDC_CLIENT_ID` /
`LITELLM_OIDC_CLIENT_SECRET` into `authentik/authentik-secrets`. Do not rotate
these after virtual keys or sessions have been issued. Re-run Authentik so it
picks up the new client credentials before its blueprint reapplies.

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
