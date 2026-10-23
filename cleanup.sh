#!/usr/bin/env bash
# Remove resources this tutorial created. Leaves OpenShift AI, GPU operators,
# and other pre-existing cluster components in place.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh [options]
  --dry-run          Print mutating commands without changing the cluster
  --yes              Do not prompt for confirmation
  --keep-operators   Leave RHCL, OpenTelemetry, and COO subscriptions installed
  --keep-demo-model  Do not scale the Demo Platform Llama deployment back up
  --help             Show this help

Deletes tutorial groups, models, governance, gateway, demo PostgreSQL, and
operators this walkthrough installed in its own namespaces. Does not uninstall
OpenShift AI or GPU operators, and does not delete the platform gateways
data-science-gateway and openshift-ai-inference. Leaves the AI Gateway
component installed; only the Models as a Service submodule is reverted.
EOF
}

dry_run=false
assume_yes=false
keep_operators=false
keep_demo_model=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    --yes) assume_yes=true ;;
    --keep-operators) keep_operators=true ;;
    --keep-demo-model) keep_demo_model=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

stage='local prerequisites'
trap 'echo "Cleanup stopped during: $stage (line $LINENO). Resolve the error above, then rerun ./cleanup.sh." >&2' ERR
step() { stage=$1; printf '\n=== %s ===\n' "$stage"; }
die() { echo "$*" >&2; exit 1; }

run() {
  if $dry_run; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

delete() {
  run oc delete --ignore-not-found --timeout=300s "$@"
}

# CRDs may be absent on a cluster that never reached that tutorial step.
try_delete() {
  if $dry_run; then
    delete "$@"
    return 0
  fi
  oc delete --ignore-not-found --timeout=300s "$@" || true
}

command -v oc >/dev/null || die 'Required command not found: oc'
command -v jq >/dev/null || die 'Required command not found: jq'

# MaasTenantConfig / AITenant finalizers require the MaaS controller. If the
# operator is already gone, strip them; the AITenant validating webhook fails
# closed with no endpoints, so skip that webhook for the patch only.
clear_tenant_finalizers() {
  $dry_run && return 0
  if oc get maastenantconfig default-tenant -n models-as-a-service --ignore-not-found -o name | grep -q .; then
    oc patch maastenantconfig default-tenant -n models-as-a-service --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
  fi
  oc get aitenant models-as-a-service -n ai-tenants --ignore-not-found -o name | grep -q . || return 0
  local idx
  idx=$(oc get validatingwebhookconfiguration maas-validating-webhook-configuration --ignore-not-found -o json 2>/dev/null \
    | jq -r '.webhooks | to_entries[] | select(.value.name == "vaitenant.kb.io") | .key' 2>/dev/null || true)
  if [[ -n "$idx" ]]; then
    oc patch validatingwebhookconfiguration maas-validating-webhook-configuration --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/webhooks/$idx/namespaceSelector\",\"value\":{\"matchLabels\":{\"maas-tutorial-skip\":\"true\"}}}]" || true
  fi
  oc patch aitenant models-as-a-service -n ai-tenants --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
  if [[ -n "$idx" ]]; then
    oc patch validatingwebhookconfiguration maas-validating-webhook-configuration --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/webhooks/$idx/namespaceSelector\",\"value\":{}}]" || true
  fi
}

wait_gone() {
  $dry_run && return 0
  oc get "$@" --ignore-not-found -o name 2>/dev/null | grep -q . || return 0
  echo "Waiting for $* to be deleted"
  oc wait --for=delete "$@" --timeout=180s || true
}

step 'Cluster access'
oc whoami
[[ $(oc auth can-i '*' '*' --all-namespaces) == yes ]] || die 'Log in with cluster-admin access'

rhcl=$(oc get subscription -A -o json | jq -c '[.items[] | select(.spec.name == "rhcl-operator")]')
rhcl_namespace=$(jq -r '.[0].metadata.namespace // empty' <<< "$rhcl")
otel=$(oc get subscription opentelemetry-product -n openshift-opentelemetry-operator --ignore-not-found -o name)
coo=$(oc get subscription cluster-observability-operator -n openshift-cluster-observability-operator --ignore-not-found -o name)
uwm=$(oc get configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found -o jsonpath='{.data.config\.yaml}')
time_slice=$(oc get configmap time-slicing-config -n nvidia-gpu-operator --ignore-not-found -o name)
llama_replicas=$(oc get deployment llama-32-3b-instruct-predictor -n my-first-model --ignore-not-found -o jsonpath='{.spec.replicas}')

cat <<EOF
This removes tutorial-created resources from the current cluster:

  Groups department-a / department-b
  Namespace ai-models (Granite, TinyLlama, generated routes and rate-limit policies)
  MaaS subscriptions, authorization policies, Config, and models-as-a-service
  Demo PostgreSQL in redhat-ods-applications
  Gateway maas-default-gateway and Route openshift-ai-inference
  Kuadrant instance in kuadrant-system
  Models as a Service flag (AI Gateway component is left as-is)
  Tutorial monitoring PVCs and Perses dashboards
EOF
if $keep_operators; then
  echo '  Operators: kept (--keep-operators)'
else
  [[ "$rhcl_namespace" == kuadrant-system ]] && echo '  RHCL subscription in kuadrant-system'
  [[ -n "$otel" ]] && echo '  OpenTelemetry in openshift-opentelemetry-operator'
  [[ -n "$coo" ]] && echo '  Cluster Observability Operator in openshift-cluster-observability-operator'
fi
[[ "$uwm" == $'enableUserWorkload: true\n' || "$uwm" == 'enableUserWorkload: true' ]] && \
  echo '  cluster-monitoring-config (tutorial-only enableUserWorkload: true)'
[[ -n "$time_slice" ]] && echo '  GPU time-slicing ConfigMap'
if ! $keep_demo_model && [[ "$llama_replicas" == 0 ]]; then
  echo '  Restore my-first-model/llama-32-3b-instruct-predictor to 1 replica'
fi

cat <<'EOF'

Left in place: OpenShift AI, NVIDIA GPU Operator, KServe, the AI Gateway
component and its namespaces (ai-tenants, redhat-ai-gateway-infra), platform
gateways data-science-gateway and openshift-ai-inference, authorino-operator in
openshift-operators, and any RHCL subscription outside kuadrant-system.
EOF

if ! $assume_yes && ! $dry_run; then
  read -r -p 'Proceed? [y/N] ' confirm
  [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]] || die 'Cleanup cancelled'
fi

step 'Models and governance'
delete maasauthpolicy standard-access limited-access -n models-as-a-service
delete maassubscription standard-plan limited-plan -n models-as-a-service
delete group department-a department-b
if $dry_run; then
  delete namespace ai-models
elif ! oc delete namespace ai-models --ignore-not-found --timeout=600s; then
  echo 'ai-models is still terminating; skip restoring the Demo Platform Llama'
  keep_demo_model=true
fi

# Drain tenants while the MaaS controller can still honor finalizers. Disabling
# the submodule first leaves namespaces Terminating and deadlocks reinstall.
# Do not wait for Config itself: the operator recreates it while MaaS is Managed.
step 'MaaS tenants'
try_delete config.maas.opendatahub.io default
wait_gone maastenantconfig/default-tenant -n models-as-a-service
wait_gone aitenant/models-as-a-service -n ai-tenants
# AITenant lives in ai-tenants (kept). A failed key-revocation Job leaves its
# cleanup finalizer in place; the models-as-a-service delete path never sees it.
if ! $dry_run && oc get aitenant models-as-a-service -n ai-tenants --ignore-not-found -o name | grep -q .; then
  echo 'AITenant still present; clearing tenant finalizers'
  clear_tenant_finalizers
  wait_gone aitenant/models-as-a-service -n ai-tenants
fi
# Keep ai-tenants and redhat-ai-gateway-infra: the AI Gateway operator
# recreates them while aigateway stays Managed.
if $dry_run; then
  delete namespace models-as-a-service
elif ! oc delete namespace models-as-a-service --ignore-not-found --timeout=300s; then
  echo 'models-as-a-service still terminating; clearing tenant finalizers'
  clear_tenant_finalizers
  oc delete namespace models-as-a-service --ignore-not-found --timeout=180s || \
    echo 'models-as-a-service still terminating; rerun ./cleanup.sh after it finishes'
fi

step 'Revert OpenShift AI feature flags'
run oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "aigateway": {
        "modelsAsAService": { "managementState": "Removed" }
      }
    }
  }
}'
run oc patch dscinitialization default-dsci --type=merge -p '{
  "spec": { "monitoring": { "managementState": "Removed" } }
}'
run oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {
    "dashboardConfig": {
      "modelAsService": false,
      "genAiStudio": false,
      "observabilityDashboard": false
    }
  }
}'
wait_gone deployment/maas-api -n redhat-ai-gateway-infra
try_delete job maas-api-revoke-keys-models-as-a-service -n redhat-ai-gateway-infra
try_delete config.maas.opendatahub.io default

step 'Demo database'
delete -f chapter-1/5-maas-db.yml

step 'Tutorial gateway'
delete telemetrypolicy maas-telemetry -n openshift-ingress
delete authpolicy maas-gateway-auth -n openshift-ingress
delete tokenratelimitpolicy gateway-default-deny -n openshift-ingress
delete gateway maas-default-gateway -n openshift-ingress
delete route openshift-ai-inference -n openshift-ingress
delete configmap gw-options -n openshift-ingress
delete secret maas-gw-service-tls -n openshift-ingress

step 'Kuadrant'
delete kuadrant kuadrant -n kuadrant-system
if $keep_operators; then
  echo 'Keeping RHCL (--keep-operators)'
elif [[ "$rhcl_namespace" == kuadrant-system ]]; then
  delete -f chapter-1/0-connectivity-link.yml
else
  [[ -n "$rhcl_namespace" ]] && echo "Keeping reused RHCL subscription in $rhcl_namespace"
  delete namespace kuadrant-system
fi

step 'Observability leftovers'
wait_gone pod/prometheus-data-science-monitoringstack-0 -n redhat-ods-monitoring
wait_gone pod/data-science-perses-0 -n redhat-ods-monitoring
try_delete pvc prometheus-data-science-monitoringstack-db-prometheus-data-science-monitoringstack-0 \
  storage-data-science-perses-0 -n redhat-ods-monitoring
try_delete servicemonitor limitador-metrics -n redhat-ods-monitoring

step 'Observability operators'
if $keep_operators; then
  echo 'Keeping OpenTelemetry and COO (--keep-operators)'
else
  [[ -n "$otel" ]] && delete -f chapter-1/opentelemetry-subscription.yml
  [[ -n "$coo" ]] && delete -f chapter-1/coo-subscription.yml
fi

# rhods-operator can recreate llm-d Perses dashboards after the first delete.
step 'Perses dashboards'
try_delete persesdashboard --all -n redhat-ods-monitoring
try_delete servicemonitor limitador-metrics -n redhat-ods-monitoring

step 'User workload monitoring'
if [[ -z "$uwm" ]]; then
  echo 'No cluster-monitoring-config to remove'
elif [[ "$uwm" == $'enableUserWorkload: true\n' || "$uwm" == 'enableUserWorkload: true' ]]; then
  delete configmap cluster-monitoring-config -n openshift-monitoring
else
  echo 'Leaving cluster-monitoring-config (it has settings beyond this tutorial)'
fi

step 'GPU time-slicing'
if [[ -n "$time_slice" ]]; then
  device_plugin=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.devicePlugin.config.name}' 2>/dev/null || true)
  if [[ "$device_plugin" == time-slicing-config ]]; then
    run oc patch clusterpolicy gpu-cluster-policy --type=merge \
      -p '{"spec":{"devicePlugin":{"config":{"name":"","default":""}}}}'
  fi
  delete configmap time-slicing-config -n nvidia-gpu-operator
fi

step 'Demo Platform Llama'
if $keep_demo_model; then
  echo 'Leaving llama-32-3b-instruct-predictor (--keep-demo-model)'
elif [[ "$llama_replicas" == 0 ]]; then
  run oc scale deployment llama-32-3b-instruct-predictor -n my-first-model --replicas=1
fi

echo
if $dry_run; then
  echo 'Dry run complete. Re-run without --dry-run to apply.'
else
  echo 'Tutorial cleanup complete. OpenShift AI and GPU operators were left installed.'
fi
