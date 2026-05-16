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
