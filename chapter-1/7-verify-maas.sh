#!/usr/bin/env bash
# Read-only checks for the OpenShift AI 3.5 MaaS setup.
set -uo pipefail
failures=0
check() {
  if "$@"; then
    printf '   PASS\n'
  else
    printf '   FAIL\n'
    failures=$((failures + 1))
  fi
}

echo 'MaaS prerequisites verification (OpenShift AI 3.5)'
echo '1. Cluster connection'
check oc whoami

echo '2. Installed OpenShift AI release'
RHOAI_CSV=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
RHOAI_VERSION=$(oc get csv "$RHOAI_CSV" -n redhat-ods-operator -o jsonpath='{.spec.version}' 2>/dev/null || true)
printf '   %s (%s)\n' "$RHOAI_CSV" "$RHOAI_VERSION"
check bash -c '[[ "$1" == 3.5.* ]]' _ "$RHOAI_VERSION"
check oc wait csv "$RHOAI_CSV" -n redhat-ods-operator --for=jsonpath='{.status.phase}'=Succeeded --timeout=5s

echo '3. Kuadrant'
check oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=5s
RHCL_SUBSCRIPTIONS=$(oc get subscription -A -o json 2>/dev/null || echo '{"items":[]}')
RHCL_NAMESPACE=$(jq -r '[.items[] | select(.spec.name == "rhcl-operator")][0].metadata.namespace // empty' <<< "$RHCL_SUBSCRIPTIONS")
RHCL_SUBSCRIPTION=$(jq -r '[.items[] | select(.spec.name == "rhcl-operator")][0].metadata.name // empty' <<< "$RHCL_SUBSCRIPTIONS")
RHCL_CSV=$(oc get subscription "$RHCL_SUBSCRIPTION" -n "$RHCL_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
check oc wait csv "$RHCL_CSV" -n "$RHCL_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5s

echo '4. MaaS component and tenant'
MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || true)
check test "$MAAS_STATE" = Managed
check oc wait datasciencecluster/default-dsc --for=condition=ModelsAsAServiceReady --timeout=5s
check oc wait maastenantconfig/default-tenant -n models-as-a-service --for=condition=Ready --timeout=5s
check oc wait deployment/maas-api -n redhat-ai-gateway-infra --for=condition=Available --timeout=5s

echo '5. User workload monitoring'
UWM_CONFIG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
check bash -c '[[ "$1" =~ enableUserWorkload:[[:space:]]*true ]]' _ "$UWM_CONFIG"
check oc rollout status statefulset/prometheus-user-workload -n openshift-user-workload-monitoring --timeout=5s

echo '6. Database secret'
check oc get secret maas-db-config -n redhat-ai-gateway-infra -o name
check oc wait deployment/maas-postgres -n redhat-ods-applications --for=condition=Available --timeout=5s

echo '7. Gateway and telemetry'
check oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=5s
check oc wait telemetrypolicy/maas-telemetry -n openshift-ingress --for=condition=Enforced --timeout=5s
check oc get podmonitor kuadrant-limitador-monitor -n kuadrant-system -o name

echo '8. KServe and llm-d prerequisites'
KSERVE_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)
check test "$KSERVE_STATE" = Managed
check oc wait datasciencecluster/default-dsc --for=condition=KserveLLMInferenceServiceDependencies --timeout=5s
check oc get crd llminferenceservices.serving.kserve.io inferencepools.inference.networking.k8s.io -o name

echo '9. Authorino TLS and dashboard configuration'
check oc wait authorino/authorino -n kuadrant-system --for=condition=Ready --timeout=5s
AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
check test "$AUTHORINO_TLS" = true
check oc get secret authorino-server-cert -n kuadrant-system -o name
check oc rollout status deployment/authorino -n kuadrant-system --timeout=5s
check oc wait datasciencecluster/default-dsc --for=condition=DashboardReady --timeout=5s
check oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=5s
DASHBOARD_CONFIG=$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o json 2>/dev/null || echo '{}')
check jq -e '.spec.dashboardConfig | .modelAsService == true and .genAiStudio == true and .observabilityDashboard == true' <<< "$DASHBOARD_CONFIG"

echo '10. External inference gateway'
ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)
check test -n "$ROUTE_HOST"
GATEWAY=$(oc get gateway maas-default-gateway -n openshift-ingress -o json 2>/dev/null || echo '{}')
check jq -e --arg host "$ROUTE_HOST" '.spec.listeners |
  any(.[]; .name == "http" and .hostname == $host) and
  ([.[] | select(.protocol == "HTTPS" or .protocol == "TLS")][0].hostname == $host) and
  any(.[]; .name == "https-router" and .protocol == "HTTPS" and .port == 443 and (.hostname // "") == "")' <<< "$GATEWAY"
check oc rollout status deployment -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --timeout=5s
if [[ -n "$ROUTE_HOST" ]]; then
  # No groups or API keys exist yet in Chapter 1; auth rejections are expected.
  HTTP_STATUS=$(curl -ksS --max-time 30 -o /dev/null -w '%{http_code}' "https://$ROUTE_HOST/maas-api/v1/models")
  printf '   MaaS endpoint HTTP %s (expected 200, 401, or 403)\n' "$HTTP_STATUS"
  check bash -c '[[ "$1" == 200 || "$1" == 401 || "$1" == 403 ]]' _ "$HTTP_STATUS"
fi

echo '11. MaaS tenant discovery (used by the API Keys dashboard)'
check oc exec -i -n redhat-ods-applications deployment/rhods-dashboard -c rhods-dashboard -- node - "$ROUTE_HOST" <<'JS'
const fs = require('fs');
const https = require('https');
const token = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token', 'utf8').trim();
const ca = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt');
const req = https.get('https://maas-api.redhat-ai-gateway-infra.svc.cluster.local:8443/v1/tenants', {
  ca, headers: { Authorization: 'Bearer ' + token }, timeout: 10000,
}, res => {
  let body = '';
  res.on('data', chunk => body += chunk);
  res.on('end', () => {
    try {
      const gateway = JSON.parse(body).tenants?.[0]?.gateway;
      if (res.statusCode !== 200 || gateway?.externalUrl !== 'https://' + process.argv[2] || gateway?.port !== 443) {
        throw new Error('HTTP ' + res.statusCode + ': ' + body);
      }
      console.log('   Discovered ' + gateway.externalUrl);
    } catch (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  });
});
req.on('timeout', () => req.destroy(new Error('Tenant discovery timed out')));
req.on('error', error => { console.error(error.message); process.exitCode = 1; });
JS

printf '\nFailed checks: %s\n' "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
