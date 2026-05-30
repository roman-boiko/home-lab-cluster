# LiteLLM

LiteLLM is deployed from GitOps as `platform/litellm` and exposed through the
public Gateway at:

```text
https://llms.home.rboiko.com
```

The Admin UI uses Authentik OIDC. The required callback URL in Authentik is:

```text
https://llms.home.rboiko.com/sso/callback
```

Runtime secrets are intentionally not committed. Create or refresh them after
the `litellm` namespace exists:

```bash
scripts/create-litellm-secret.sh
```

This creates `litellm/litellm-runtime-secrets` with the LiteLLM master key,
salt key, and OIDC client settings, and patches `authentik/authentik-secrets`
with the matching LiteLLM OIDC client secret.

The initial `model_list` is empty. Add provider models and API-key references
to `clusters/lab/gitops/platform/litellm/manifests/configmap.yaml`, and store
actual provider keys in Kubernetes secrets, not in Git.
