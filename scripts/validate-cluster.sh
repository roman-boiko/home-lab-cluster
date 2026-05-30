#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${ROOT_DIR}/kubeconfig/lab-k3s.yaml}"
INVENTORY="${ANSIBLE_INVENTORY:-${ROOT_DIR}/ansible/inventory/hosts.ini}"
EXPECTED_NODES="${EXPECTED_NODES:-4}"
ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"
EXPECTED_K3S_VERSION="$(sed -n 's/^k3s_version: "\(.*\)"/\1/p' "${ROOT_DIR}/ansible/group_vars/all.yml")"

export KUBECONFIG="${KUBECONFIG_PATH}"
export ANSIBLE_LOCAL_TEMP

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

info() {
  printf 'INFO: %s\n' "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

kubectl_wait() {
  kubectl "$@" >/dev/null
}

require_cmd kubectl
require_cmd ansible

[[ -f "${KUBECONFIG_PATH}" ]] || fail "Kubeconfig not found at ${KUBECONFIG_PATH}. Run scripts/bootstrap-cluster.sh first."
[[ -f "${INVENTORY}" ]] || fail "Ansible inventory not found at ${INVENTORY}."
mkdir -p "${ANSIBLE_LOCAL_TEMP}"

info "Using kubeconfig: ${KUBECONFIG_PATH}"
info "Using inventory: ${INVENTORY}"

kubectl version --client >/dev/null
pass "kubectl is available"

kubectl_wait cluster-info
pass "Kubernetes API is reachable"

actual_nodes="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
[[ "${actual_nodes}" == "${EXPECTED_NODES}" ]] || fail "Expected ${EXPECTED_NODES} nodes, found ${actual_nodes}"
pass "Expected node count is ${EXPECTED_NODES}"

not_ready_nodes="$(kubectl get nodes --no-headers | awk '$2 !~ /Ready/ {print $1}')"
[[ -z "${not_ready_nodes}" ]] || fail "Not all nodes are Ready: ${not_ready_nodes}"
pass "All nodes are Ready"

kubectl_wait -n kube-system rollout status daemonset/cilium --timeout=300s
pass "Cilium daemonset is rolled out"

kubectl_wait -n kube-system rollout status deployment/cilium-operator --timeout=300s
pass "Cilium operator is rolled out"

kubectl_wait get ciliumloadbalancerippool home-lab-lb-pool
pass "Cilium LoadBalancer IP pool exists"

kubectl_wait get ciliuml2announcementpolicy home-lab-l2-announcements
pass "Cilium L2 announcement policy exists"

kubectl_wait get gatewayclass cilium
pass "Cilium GatewayClass exists"

kubectl_wait -n gateway-system get secret home-lab-gateway-tls
pass "Gateway TLS secret exists"

validate_gateway() {
  local gateway_name="$1"
  local expected_ip="$2"
  local expected_scope="$3"

  kubectl_wait -n gateway-system get gateway "${gateway_name}"
  pass "${gateway_name} Gateway exists"

  local gateway_ip
  gateway_ip="$(kubectl -n gateway-system get gateway "${gateway_name}" -o jsonpath='{.spec.addresses[0].value}')"
  [[ "${gateway_ip}" == "${expected_ip}" ]] || fail "${gateway_name} Gateway address is ${gateway_ip}, expected ${expected_ip}"
  pass "${gateway_name} Gateway uses ${expected_ip}"

  local gateway_ports
  gateway_ports="$(kubectl -n gateway-system get gateway "${gateway_name}" -o jsonpath='{range .spec.listeners[*]}{.port}{" "}{end}')"
  grep -q '443' <<< "${gateway_ports}" || fail "${gateway_name} Gateway does not expose HTTPS port 443"
  grep -q '80' <<< "${gateway_ports}" || fail "${gateway_name} Gateway does not expose HTTP port 80 for redirects"
  pass "${gateway_name} Gateway exposes HTTPS and HTTP redirect listener ports"

  local gateway_protocols
  gateway_protocols="$(kubectl -n gateway-system get gateway "${gateway_name}" -o jsonpath='{range .spec.listeners[*]}{.protocol}{" "}{end}')"
  grep -q 'HTTPS' <<< "${gateway_protocols}" || fail "${gateway_name} Gateway has no HTTPS listener"
  grep -q 'HTTP' <<< "${gateway_protocols}" || fail "${gateway_name} Gateway has no HTTP redirect listener"
  pass "${gateway_name} Gateway listener protocols include HTTPS and HTTP redirect"

  local gateway_route_scope
  gateway_route_scope="$(kubectl -n gateway-system get gateway "${gateway_name}" -o yaml)"
  grep -q "home-lab.rboiko.com/gateway-scope: ${expected_scope}" <<< "${gateway_route_scope}" \
    || fail "${gateway_name} HTTPS route scope is not restricted to ${expected_scope} namespaces"
  pass "${gateway_name} Gateway restricts HTTPS routes to ${expected_scope} namespaces"
}

validate_redirect_route() {
  local route_name="$1"

  kubectl_wait -n gateway-system get httproute "${route_name}"
  pass "${route_name} HTTP to HTTPS redirect route exists"

  local redirect_scheme
  redirect_scheme="$(kubectl -n gateway-system get httproute "${route_name}" -o jsonpath='{.spec.rules[0].filters[0].requestRedirect.scheme}')"
  [[ "${redirect_scheme}" == "https" ]] || fail "${route_name} redirect route scheme is ${redirect_scheme}, expected https"
  pass "${route_name} HTTP redirect route targets HTTPS"

  local redirect_status
  redirect_status="$(kubectl -n gateway-system get httproute "${route_name}" -o jsonpath='{.spec.rules[0].filters[0].requestRedirect.statusCode}')"
  [[ "${redirect_status}" == "301" ]] || fail "${route_name} redirect route status is ${redirect_status}, expected 301"
  pass "${route_name} HTTP redirect route uses 301"
}

validate_private_route() {
  local namespace="$1"
  local route_name="$2"
  local expected_hostname="$3"
  local expected_backend="$4"

  kubectl_wait -n "${namespace}" get httproute "${route_name}"
  pass "${namespace}/${route_name} private HTTPRoute exists"

  local route_parent
  route_parent="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.parentRefs[0].name}')"
  [[ "${route_parent}" == "private-https" ]] || fail "${namespace}/${route_name} parent is ${route_parent:-unset}, expected private-https"
  pass "${namespace}/${route_name} attaches to the private Gateway"

  local route_hostname
  route_hostname="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.hostnames[0]}')"
  [[ "${route_hostname}" == "${expected_hostname}" ]] || fail "${namespace}/${route_name} hostname is ${route_hostname:-unset}"
  pass "${namespace}/${route_name} uses ${expected_hostname}"

  local route_backend
  route_backend="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.rules[0].backendRefs[0].name}')"
  [[ "${route_backend}" == "${expected_backend}" ]] || fail "${namespace}/${route_name} backend is ${route_backend:-unset}, expected ${expected_backend}"
  pass "${namespace}/${route_name} routes to ${expected_backend}"

  local route_accepted
  route_accepted="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="Accepted")]}{.status}{end}')"
  [[ "${route_accepted}" == *True* ]] || fail "${namespace}/${route_name} is not accepted by the Gateway"
  pass "${namespace}/${route_name} is accepted by the Gateway"

  local route_refs
  route_refs="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="ResolvedRefs")]}{.status}{end}')"
  [[ "${route_refs}" == *True* ]] || fail "${namespace}/${route_name} backend references are not resolved"
  pass "${namespace}/${route_name} backend references are resolved"
}

validate_public_route() {
  local namespace="$1"
  local route_name="$2"
  local expected_hostname="$3"
  local expected_backend="$4"

  kubectl_wait -n "${namespace}" get httproute "${route_name}"
  pass "${namespace}/${route_name} public HTTPRoute exists"

  local route_parent
  route_parent="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.parentRefs[0].name}')"
  [[ "${route_parent}" == "public-https" ]] || fail "${namespace}/${route_name} parent is ${route_parent:-unset}, expected public-https"
  pass "${namespace}/${route_name} attaches to the public Gateway"

  local route_hostname
  route_hostname="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.hostnames[0]}')"
  [[ "${route_hostname}" == "${expected_hostname}" ]] || fail "${namespace}/${route_name} hostname is ${route_hostname:-unset}"
  pass "${namespace}/${route_name} uses ${expected_hostname}"

  local route_backend
  route_backend="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{.spec.rules[0].backendRefs[0].name}')"
  [[ "${route_backend}" == "${expected_backend}" ]] || fail "${namespace}/${route_name} backend is ${route_backend:-unset}, expected ${expected_backend}"
  pass "${namespace}/${route_name} routes to ${expected_backend}"

  local route_accepted
  route_accepted="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="Accepted")]}{.status}{end}')"
  [[ "${route_accepted}" == *True* ]] || fail "${namespace}/${route_name} is not accepted by the Gateway"
  pass "${namespace}/${route_name} is accepted by the Gateway"

  local route_refs
  route_refs="$(kubectl -n "${namespace}" get httproute "${route_name}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="ResolvedRefs")]}{.status}{end}')"
  [[ "${route_refs}" == *True* ]] || fail "${namespace}/${route_name} backend references are not resolved"
  pass "${namespace}/${route_name} backend references are resolved"
}

validate_authentik_proxy_headers() {
  local namespace="$1"
  local route_name="$2"

  local route_headers
  route_headers="$(kubectl -n "${namespace}" get httproute "${route_name}" -o yaml)"
  grep -q 'name: X-Forwarded-Proto' <<< "${route_headers}" \
    || fail "${namespace}/${route_name} does not set X-Forwarded-Proto for Authentik"
  grep -q 'value: https' <<< "${route_headers}" \
    || fail "${namespace}/${route_name} does not force X-Forwarded-Proto=https for Authentik"
  grep -q 'name: X-Forwarded-Port' <<< "${route_headers}" \
    || fail "${namespace}/${route_name} does not set X-Forwarded-Port for Authentik"
  grep -q 'value: "443"' <<< "${route_headers}" \
    || fail "${namespace}/${route_name} does not force X-Forwarded-Port=443 for Authentik"
  pass "${namespace}/${route_name} forwards HTTPS headers to Authentik"
}

validate_gateway public-https 192.168.5.100 public
validate_gateway private-https 192.168.5.101 private
validate_redirect_route public-http-to-https-redirect
validate_redirect_route private-http-to-https-redirect

cilium_config="$(kubectl -n kube-system exec ds/cilium -- cilium-dbg config --all)"
grep -q 'EnableL2Announcements[[:space:]]*: true' <<< "${cilium_config}"
pass "Cilium L2 announcements are enabled"

cilium_status="$(kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose)"
grep -q 'KubeProxyReplacement:[[:space:]]*True' <<< "${cilium_status}"
pass "Cilium kube-proxy replacement is enabled"

if command -v cilium >/dev/null 2>&1; then
  cilium status --wait --wait-duration 5m >/dev/null
  pass "Cilium status is healthy"
else
  info "Cilium CLI not found locally; skipped cilium status check"
fi

if kubectl -n kube-system get daemonset kube-flannel-ds >/dev/null 2>&1; then
  fail "Flannel daemonset exists; k3s should be installed with flannel-backend=none"
fi
pass "Flannel is not installed"

if kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^svclb-'; then
  fail "ServiceLB pods exist; servicelb should be disabled"
fi
pass "ServiceLB pods are absent"

if kubectl -n kube-system get helmchart traefik >/dev/null 2>&1; then
  fail "k3s Traefik HelmChart exists; traefik should be disabled"
fi
pass "k3s Traefik HelmChart is absent"

ansible -i "${INVENTORY}" k3s_servers -b -m command -a 'grep -q "flannel-backend: none" /etc/rancher/k3s/config.yaml' >/dev/null
pass "k3s server config disables Flannel"

ansible -i "${INVENTORY}" k3s_servers -b -m command -a 'grep -q "disable-network-policy: true" /etc/rancher/k3s/config.yaml' >/dev/null
pass "k3s server config disables built-in network policy"

ansible -i "${INVENTORY}" k3s_servers -b -m shell -a 'grep -A5 "^disable:" /etc/rancher/k3s/config.yaml | grep -q "servicelb"' >/dev/null
pass "k3s server config disables ServiceLB"

ansible -i "${INVENTORY}" k3s_servers -b -m shell -a 'grep -A5 "^disable:" /etc/rancher/k3s/config.yaml | grep -q "traefik"' >/dev/null
pass "k3s server config disables Traefik"

kubectl_wait -n argocd rollout status deployment/argocd-server --timeout=300s
pass "Argo CD server is rolled out"

kubectl_wait -n argocd rollout status deployment/argocd-repo-server --timeout=300s
pass "Argo CD repo server is rolled out"

argocd_gateway_scope="$(kubectl get namespace argocd -o jsonpath='{.metadata.labels.home-lab\.rboiko\.com/gateway-scope}')"
[[ "${argocd_gateway_scope}" == "private" ]] || fail "argocd namespace Gateway scope is ${argocd_gateway_scope:-unset}, expected private"
pass "Argo CD namespace is scoped to the private Gateway"

argocd_server_insecure="$(kubectl -n argocd get configmap argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}')"
[[ "${argocd_server_insecure}" == "true" ]] || fail "Argo CD server.insecure is ${argocd_server_insecure:-unset}, expected true"
pass "Argo CD server is configured for Gateway TLS termination"

kubectl_wait -n argocd get secret authentik-oidc
pass "Argo CD Authentik OIDC secret exists"

argocd_oidc_config="$(kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.oidc\.config}')"
grep -q 'issuer: https://auth.home.rboiko.com/application/o/argocd/' <<< "${argocd_oidc_config}" \
  || fail "Argo CD OIDC issuer is not configured for Authentik"
grep -q 'clientSecret: $authentik-oidc:clientSecret' <<< "${argocd_oidc_config}" \
  || fail "Argo CD OIDC client secret does not reference authentik-oidc"
pass "Argo CD OIDC config points to Authentik"

argocd_rbac_config="$(kubectl -n argocd get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}')"
grep -q 'g, ArgoCD Admins, role:admin' <<< "${argocd_rbac_config}" \
  || fail "Argo CD RBAC does not map ArgoCD Admins to role:admin"
pass "Argo CD RBAC maps Authentik admin group"

kubectl_wait -n argocd get httproute argocd
pass "Argo CD private HTTPRoute exists"

argocd_route_parent="$(kubectl -n argocd get httproute argocd -o jsonpath='{.spec.parentRefs[0].name}')"
[[ "${argocd_route_parent}" == "private-https" ]] || fail "Argo CD HTTPRoute parent is ${argocd_route_parent:-unset}, expected private-https"
pass "Argo CD HTTPRoute attaches to the private Gateway"

argocd_route_hostname="$(kubectl -n argocd get httproute argocd -o jsonpath='{.spec.hostnames[0]}')"
[[ "${argocd_route_hostname}" == "argocd.home.rboiko.com" ]] || fail "Argo CD HTTPRoute hostname is ${argocd_route_hostname:-unset}"
pass "Argo CD HTTPRoute uses argocd.home.rboiko.com"

kubectl_wait -n argocd get application home-lab-cluster
pass "Argo CD root application exists"

kubectl_wait -n argocd get application argocd
pass "Argo CD self-management application exists"

root_app_sync_status="$(kubectl -n argocd get application home-lab-cluster -o jsonpath='{.status.sync.status}')"
[[ "${root_app_sync_status}" == "Synced" ]] || fail "Argo CD root application is ${root_app_sync_status:-unknown}, expected Synced"
pass "Argo CD root application is synced"

argocd_app_sync_status="$(kubectl -n argocd get application argocd -o jsonpath='{.status.sync.status}')"
[[ "${argocd_app_sync_status}" == "Synced" ]] || fail "Argo CD self-management application is ${argocd_app_sync_status:-unknown}, expected Synced"
pass "Argo CD self-management application is synced"

kubectl_wait get namespace home-lab-system
pass "GitOps-managed home-lab-system namespace exists"

kubectl_wait -n argocd get application sealed-secrets
pass "Sealed Secrets Argo CD application exists"

kubectl_wait -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=300s
pass "Sealed Secrets controller is rolled out"

kubectl_wait -n argocd get application kured
pass "kured Argo CD application exists"

kured_app_sync_status="$(kubectl -n argocd get application kured -o jsonpath='{.status.sync.status}')"
[[ "${kured_app_sync_status}" == "Synced" ]] || fail "kured Argo CD application is ${kured_app_sync_status:-unknown}, expected Synced"
pass "kured Argo CD application is synced"

kubectl_wait -n kured rollout status daemonset/kured --timeout=300s
pass "kured daemonset is rolled out"

kubectl_wait -n argocd get application system-upgrade-controller
pass "system-upgrade-controller Argo CD application exists"

system_upgrade_app_sync_status="$(kubectl -n argocd get application system-upgrade-controller -o jsonpath='{.status.sync.status}')"
[[ "${system_upgrade_app_sync_status}" == "Synced" ]] \
  || fail "system-upgrade-controller Argo CD application is ${system_upgrade_app_sync_status:-unknown}, expected Synced"
pass "system-upgrade-controller Argo CD application is synced"

kubectl_wait -n system-upgrade rollout status deployment/system-upgrade-controller --timeout=300s
pass "system-upgrade-controller deployment is rolled out"

kubectl_wait get crd plans.upgrade.cattle.io
pass "system-upgrade-controller Plan CRD exists"

kubectl_wait -n argocd get application k3s-upgrade-plans
pass "k3s upgrade Plans Argo CD application exists"

k3s_plans_app_sync_status="$(kubectl -n argocd get application k3s-upgrade-plans -o jsonpath='{.status.sync.status}')"
[[ "${k3s_plans_app_sync_status}" == "Synced" ]] \
  || fail "k3s upgrade Plans Argo CD application is ${k3s_plans_app_sync_status:-unknown}, expected Synced"
pass "k3s upgrade Plans Argo CD application is synced"

for plan in k3s-server k3s-agent; do
  kubectl_wait -n system-upgrade get plan "${plan}"
  pass "${plan} system-upgrade Plan exists"

  plan_version="$(kubectl -n system-upgrade get plan "${plan}" -o jsonpath='{.spec.version}')"
  [[ "${plan_version}" == "${EXPECTED_K3S_VERSION}" ]] \
    || fail "${plan} version is ${plan_version:-unset}, expected ${EXPECTED_K3S_VERSION}"
  pass "${plan} matches pinned k3s version ${EXPECTED_K3S_VERSION}"

  plan_concurrency="$(kubectl -n system-upgrade get plan "${plan}" -o jsonpath='{.spec.concurrency}')"
  [[ "${plan_concurrency}" == "1" ]] || fail "${plan} concurrency is ${plan_concurrency:-unset}, expected 1"
  pass "${plan} upgrades one node at a time"
done

kubectl_wait -n argocd get application cloudnative-pg
pass "CloudNativePG Argo CD application exists"

cloudnative_pg_app_sync_status="$(kubectl -n argocd get application cloudnative-pg -o jsonpath='{.status.sync.status}')"
[[ "${cloudnative_pg_app_sync_status}" == "Synced" ]] || fail "CloudNativePG Argo CD application is ${cloudnative_pg_app_sync_status:-unknown}, expected Synced"
pass "CloudNativePG Argo CD application is synced"

kubectl_wait -n cnpg-system rollout status deployment/cloudnative-pg --timeout=300s
pass "CloudNativePG operator is rolled out"

kubectl_wait -n argocd get application authentik
pass "Authentik Argo CD application exists"

authentik_app_sync_status="$(kubectl -n argocd get application authentik -o jsonpath='{.status.sync.status}')"
[[ "${authentik_app_sync_status}" == "Synced" ]] || fail "Authentik Argo CD application is ${authentik_app_sync_status:-unknown}, expected Synced"
pass "Authentik Argo CD application is synced"

authentik_gateway_scope="$(kubectl get namespace authentik -o jsonpath='{.metadata.labels.home-lab\.rboiko\.com/gateway-scope}')"
[[ "${authentik_gateway_scope}" == "public" ]] || fail "authentik namespace Gateway scope is ${authentik_gateway_scope:-unset}, expected public"
pass "Authentik namespace is scoped to the public Gateway"

kubectl_wait -n authentik get secret authentik-secrets
pass "Authentik runtime secret exists"

kubectl_wait -n authentik get configmap home-lab-authentik-blueprints
pass "Authentik home-lab blueprint ConfigMap exists"

kubectl_wait -n authentik get configmap home-lab-authentik-brand-blueprint
pass "Authentik brand blueprint ConfigMap exists"

kubectl_wait -n authentik get configmap home-lab-authentik-brand-assets
pass "Authentik brand asset ConfigMap exists"

authentik_brand_blueprint="$(kubectl -n authentik get configmap home-lab-authentik-brand-blueprint -o jsonpath='{.data.home-lab-brand\.yaml}')"
grep -q "branding_title: Welcome to Roman's SSO page" <<< "${authentik_brand_blueprint}" \
  || fail "Authentik blueprint does not configure the home lab Brand title"
grep -q 'branding_logo: home-lab/robot-logo.svg' <<< "${authentik_brand_blueprint}" \
  || fail "Authentik blueprint does not configure the robot logo"
grep -q 'branding_favicon: home-lab/robot-favicon.svg' <<< "${authentik_brand_blueprint}" \
  || fail "Authentik blueprint does not configure the robot favicon"
grep -q 'color: var(--ak-neutral-text)' <<< "${authentik_brand_blueprint}" \
  || fail "Authentik brand blueprint does not force readable dark text"
pass "Authentik blueprint defines home lab Brand title and robot assets"

authentik_blueprint="$(kubectl -n authentik get configmap home-lab-authentik-blueprints -o jsonpath='{.data.home-lab-apps\.yaml}')"
grep -q 'scope_name: groups' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not define an Argo CD groups scope"
grep -q 'authorization_code' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not enable authorization_code grant for Argo CD"
grep -q 'signing_key: !Find \[authentik_crypto.certificatekeypair, \[name, authentik Self-signed Certificate\]\]' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not configure an RS256 signing key for Argo CD"
pass "Authentik blueprint defines Argo CD OIDC groups, grant types, and signing key"
grep -q 'scope_name: litellm_role' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not define the LiteLLM role scope"
grep -q 'client_id: !Env LITELLM_OIDC_CLIENT_ID' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not configure the LiteLLM OIDC client ID"
grep -q 'url: https://llms.home.rboiko.com/sso/callback' <<< "${authentik_blueprint}" \
  || fail "Authentik blueprint does not configure the LiteLLM OIDC callback"
pass "Authentik blueprint defines LiteLLM OIDC provider and role scope"
grep -q 'internal_host: http://longhorn-frontend.longhorn-system.svc$' <<< "${authentik_blueprint}" \
  || fail "Authentik Longhorn proxy provider does not use a resolvable in-cluster service name"
grep -q 'internal_host: http://hubble-ui.kube-system.svc$' <<< "${authentik_blueprint}" \
  || fail "Authentik Hubble proxy provider does not use a resolvable in-cluster service name"
grep -q 'internal_host: http://litellm.litellm.svc:4000$' <<< "${authentik_blueprint}" \
  || fail "Authentik LiteLLM proxy provider does not use a resolvable in-cluster service name"
pass "Authentik proxy providers use resolvable in-cluster service names"

authentik_live_proxy_state="$(
  kubectl -n authentik exec deploy/authentik-server -- ak shell -c \
    "from authentik.blueprints.models import BlueprintInstance; from authentik.providers.proxy.models import ProxyProvider; from authentik.outposts.models import Outpost; bp=BlueprintInstance.objects.get(name='home-lab-apps'); has_provider=ProxyProvider.objects.filter(name='LiteLLM UI', external_host='https://llms.home.rboiko.com', internal_host='http://litellm.litellm.svc:4000').exists(); has_outpost=Outpost.objects.filter(name='authentik Embedded Outpost', providers__name='LiteLLM UI').exists(); print(f'{bp.status}:{has_provider}:{has_outpost}')" \
    2>/dev/null \
    | tail -n 1
)"
IFS=':' read -r authentik_blueprint_status litellm_proxy_exists litellm_outpost_exists <<< "${authentik_live_proxy_state}"
[[ "${authentik_blueprint_status}" == "successful" ]] \
  || fail "Authentik home-lab-apps blueprint status is ${authentik_blueprint_status:-unknown}, expected successful"
[[ "${litellm_proxy_exists}" == "True" ]] \
  || fail "Authentik LiteLLM UI proxy provider does not exist"
[[ "${litellm_outpost_exists}" == "True" ]] \
  || fail "Authentik embedded outpost does not include the LiteLLM UI proxy provider"
pass "Authentik live state includes LiteLLM UI proxy provider"

for key in \
  AUTHENTIK_SECRET_KEY \
  AUTHENTIK_POSTGRESQL__HOST \
  AUTHENTIK_POSTGRESQL__NAME \
  AUTHENTIK_POSTGRESQL__USER \
  AUTHENTIK_POSTGRESQL__PORT \
  AUTHENTIK_POSTGRESQL__PASSWORD \
  ARGOCD_OIDC_CLIENT_ID \
  ARGOCD_OIDC_CLIENT_SECRET \
  LITELLM_OIDC_CLIENT_ID \
  LITELLM_OIDC_CLIENT_SECRET \
  username \
  password \
  postgres-password; do
  kubectl -n authentik get secret authentik-secrets -o "jsonpath={.data.${key}}" | grep -q . \
    || fail "Authentik runtime secret is missing ${key}"
done
pass "Authentik runtime secret contains required keys"

authentik_postgres_host="$(kubectl -n authentik get secret authentik-secrets -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__HOST}')"
expected_authentik_postgres_host="$(printf '%s' authentik-postgres-rw | base64 | tr -d '\n')"
[[ "${authentik_postgres_host}" == "${expected_authentik_postgres_host}" ]] \
  || fail "Authentik PostgreSQL host does not point to authentik-postgres-rw"
pass "Authentik runtime secret points to CloudNativePG"

kubectl_wait -n argocd get application authentik-postgres
pass "Authentik PostgreSQL Argo CD application exists"

authentik_postgres_app_sync_status="$(kubectl -n argocd get application authentik-postgres -o jsonpath='{.status.sync.status}')"
[[ "${authentik_postgres_app_sync_status}" == "Synced" ]] || fail "Authentik PostgreSQL Argo CD application is ${authentik_postgres_app_sync_status:-unknown}, expected Synced"
pass "Authentik PostgreSQL Argo CD application is synced"

authentik_postgres_ready="$(kubectl -n authentik get cluster.postgresql.cnpg.io authentik-postgres -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
[[ "${authentik_postgres_ready}" == "True" ]] || fail "Authentik CloudNativePG cluster is not Ready"
pass "Authentik CloudNativePG cluster is Ready"

kubectl_wait -n authentik get service authentik-postgres-rw
pass "Authentik CloudNativePG read-write service exists"

kubectl_wait -n authentik rollout status deployment/authentik-server --timeout=300s
pass "Authentik server is rolled out"

kubectl_wait -n authentik rollout status deployment/authentik-worker --timeout=300s
pass "Authentik worker is rolled out"

kubectl_wait -n authentik get service authentik-server
pass "Authentik server service exists"

validate_public_route authentik authentik-server auth.home.rboiko.com authentik-server

kubectl_wait -n argocd get application litellm
pass "LiteLLM Argo CD application exists"

litellm_app_sync_status="$(kubectl -n argocd get application litellm -o jsonpath='{.status.sync.status}')"
[[ "${litellm_app_sync_status}" == "Synced" ]] || fail "LiteLLM Argo CD application is ${litellm_app_sync_status:-unknown}, expected Synced"
pass "LiteLLM Argo CD application is synced"

litellm_gateway_scope="$(kubectl get namespace litellm -o jsonpath='{.metadata.labels.home-lab\.rboiko\.com/gateway-scope}')"
[[ "${litellm_gateway_scope}" == "public" ]] || fail "litellm namespace Gateway scope is ${litellm_gateway_scope:-unset}, expected public"
pass "LiteLLM namespace is scoped to the public Gateway"

kubectl_wait -n litellm get secret litellm-runtime-secrets
pass "LiteLLM runtime secret exists"

for key in \
  LITELLM_MASTER_KEY \
  LITELLM_SALT_KEY \
  GENERIC_CLIENT_ID \
  GENERIC_CLIENT_SECRET; do
  kubectl -n litellm get secret litellm-runtime-secrets -o "jsonpath={.data.${key}}" | grep -q . \
    || fail "LiteLLM runtime secret is missing ${key}"
done
pass "LiteLLM runtime secret contains required keys"

litellm_postgres_ready="$(kubectl -n litellm get cluster.postgresql.cnpg.io litellm-postgres -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
[[ "${litellm_postgres_ready}" == "True" ]] || fail "LiteLLM CloudNativePG cluster is not Ready"
pass "LiteLLM CloudNativePG cluster is Ready"

kubectl_wait -n litellm get service litellm-postgres-rw
pass "LiteLLM CloudNativePG read-write service exists"

kubectl_wait -n litellm rollout status deployment/litellm --timeout=300s
pass "LiteLLM deployment is rolled out"

kubectl_wait -n litellm get service litellm
pass "LiteLLM service exists"

validate_public_route litellm litellm llms.home.rboiko.com litellm

litellm_api_path="$(kubectl -n litellm get httproute litellm -o jsonpath='{.spec.rules[0].matches[0].path.value}')"
[[ "${litellm_api_path}" == "/v1" ]] || fail "LiteLLM direct API route is ${litellm_api_path:-unset}, expected /v1"
pass "LiteLLM direct API route is limited to /v1"

litellm_ui_path="$(kubectl -n litellm get httproute litellm -o jsonpath='{.spec.rules[1].matches[0].path.value}')"
[[ "${litellm_ui_path}" == "/" ]] || fail "LiteLLM protected UI route is ${litellm_ui_path:-unset}, expected /"

litellm_ui_backend="$(kubectl -n litellm get httproute litellm -o jsonpath='{.spec.rules[1].backendRefs[0].name}')"
[[ "${litellm_ui_backend}" == "authentik-server" ]] || fail "LiteLLM UI route backend is ${litellm_ui_backend:-unset}, expected authentik-server"

litellm_ui_backend_namespace="$(kubectl -n litellm get httproute litellm -o jsonpath='{.spec.rules[1].backendRefs[0].namespace}')"
[[ "${litellm_ui_backend_namespace}" == "authentik" ]] || fail "LiteLLM UI route backend namespace is ${litellm_ui_backend_namespace:-unset}, expected authentik"
pass "LiteLLM UI route is protected by Authentik proxy outpost"
validate_authentik_proxy_headers litellm litellm

kubectl_wait -n authentik get referencegrant allow-longhorn-route-to-authentik
pass "Authentik ReferenceGrant allows Longhorn route backend"

kubectl_wait -n authentik get referencegrant allow-hubble-route-to-authentik
pass "Authentik ReferenceGrant allows Hubble route backend"

kubectl_wait -n authentik get referencegrant allow-litellm-route-to-authentik
pass "Authentik ReferenceGrant allows LiteLLM route backend"

kubectl_wait -n argocd get application cilium
pass "Cilium Argo CD application exists"

cilium_app_sync_status="$(kubectl -n argocd get application cilium -o jsonpath='{.status.sync.status}')"
[[ "${cilium_app_sync_status}" == "Synced" ]] || fail "Cilium Argo CD application is ${cilium_app_sync_status:-unknown}, expected Synced"
pass "Cilium Argo CD application is synced"

kube_system_gateway_scope="$(kubectl get namespace kube-system -o jsonpath='{.metadata.labels.home-lab\.rboiko\.com/gateway-scope}')"
[[ "${kube_system_gateway_scope}" == "private" ]] || fail "kube-system namespace Gateway scope is ${kube_system_gateway_scope:-unset}, expected private"
pass "kube-system namespace is scoped to the private Gateway"

kubectl_wait -n kube-system rollout status deployment/hubble-relay --timeout=300s
pass "Hubble Relay is rolled out"

kubectl_wait -n kube-system rollout status deployment/hubble-ui --timeout=300s
pass "Hubble UI is rolled out"

kubectl_wait -n kube-system get service hubble-ui
pass "Hubble UI service exists"

validate_private_route kube-system hubble-ui hubble.home.rboiko.com authentik-server

hubble_route_backend_namespace="$(kubectl -n kube-system get httproute hubble-ui -o jsonpath='{.spec.rules[0].backendRefs[0].namespace}')"
[[ "${hubble_route_backend_namespace}" == "authentik" ]] || fail "Hubble UI route backend namespace is ${hubble_route_backend_namespace:-unset}, expected authentik"
pass "Hubble UI route is protected by Authentik proxy outpost"
validate_authentik_proxy_headers kube-system hubble-ui

kubectl_wait -n argocd get application cert-manager
pass "cert-manager Argo CD application exists"

kubectl_wait -n argocd get application cert-manager-config
pass "cert-manager config Argo CD application exists"

kubectl_wait -n argocd get application longhorn
pass "Longhorn Argo CD application exists"

longhorn_app_sync_status="$(kubectl -n argocd get application longhorn -o jsonpath='{.status.sync.status}')"
[[ "${longhorn_app_sync_status}" == "Synced" ]] || fail "Longhorn Argo CD application is ${longhorn_app_sync_status:-unknown}, expected Synced"
pass "Longhorn Argo CD application is synced"

kubectl_wait -n cert-manager rollout status deployment/cert-manager --timeout=300s
pass "cert-manager controller is rolled out"

kubectl_wait -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
pass "cert-manager webhook is rolled out"

kubectl_wait -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=300s
pass "cert-manager cainjector is rolled out"

kubectl_wait get clusterissuer letsencrypt-prod
pass "Let's Encrypt ClusterIssuer exists"

kubectl_wait -n gateway-system get certificate home-lab-gateway
pass "Gateway wildcard Certificate exists"

certificate_dns_names="$(kubectl -n gateway-system get certificate home-lab-gateway -o jsonpath='{.spec.dnsNames[*]}')"
grep -q '\*.home.rboiko.com' <<< "${certificate_dns_names}" || fail "Gateway certificate does not include wildcard DNS name"
pass "Gateway certificate includes wildcard DNS name"

if kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1; then
  certificate_ready="$(kubectl -n gateway-system get certificate home-lab-gateway -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
  [[ "${certificate_ready}" == "True" ]] || fail "Gateway certificate is not Ready"
  pass "Gateway Let's Encrypt certificate is Ready"
else
  info "Cloudflare API token secret is missing; skipped certificate Ready check"
fi

kubectl_wait -n longhorn-system rollout status daemonset/longhorn-manager --timeout=300s
pass "Longhorn manager daemonset is rolled out"

kubectl_wait -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=300s
pass "Longhorn driver deployer is rolled out"

kubectl_wait -n longhorn-system rollout status deployment/longhorn-ui --timeout=300s
pass "Longhorn UI is rolled out"

longhorn_gateway_scope="$(kubectl get namespace longhorn-system -o jsonpath='{.metadata.labels.home-lab\.rboiko\.com/gateway-scope}')"
[[ "${longhorn_gateway_scope}" == "private" ]] || fail "longhorn-system namespace Gateway scope is ${longhorn_gateway_scope:-unset}, expected private"
pass "Longhorn namespace is scoped to the private Gateway"

validate_private_route longhorn-system longhorn longhorn.home.rboiko.com authentik-server

longhorn_route_backend_namespace="$(kubectl -n longhorn-system get httproute longhorn -o jsonpath='{.spec.rules[0].backendRefs[0].namespace}')"
[[ "${longhorn_route_backend_namespace}" == "authentik" ]] || fail "Longhorn route backend namespace is ${longhorn_route_backend_namespace:-unset}, expected authentik"
pass "Longhorn route is protected by Authentik proxy outpost"
validate_authentik_proxy_headers longhorn-system longhorn

kubectl_wait get storageclass longhorn
pass "Longhorn StorageClass exists"

default_storageclasses="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}')"
[[ "${default_storageclasses}" == "longhorn " ]] || fail "Default StorageClass is '${default_storageclasses:-none}', expected 'longhorn'"
pass "Longhorn is the only default StorageClass"

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'systemctl is-active iscsid' >/dev/null
pass "iscsid is active on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'test -e /usr/sbin/iscsiadm' >/dev/null
pass "open-iscsi tools are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v mount.nfs' >/dev/null
pass "NFS client tools are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v cryptsetup' >/dev/null
pass "cryptsetup is installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a 'command -v mkfs.ext4' >/dev/null
pass "ext4 utilities are installed on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m command -a 'systemctl is-enabled unattended-upgrades' >/dev/null
pass "unattended upgrades are enabled on all nodes"

ansible -i "${INVENTORY}" k3s_cluster -b -m shell -a '! swapon --show | grep -q .' >/dev/null
pass "swap is disabled on all nodes"

printf '\nCluster validation completed successfully.\n'
