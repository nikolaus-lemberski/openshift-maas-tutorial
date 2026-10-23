#!/usr/bin/env bash
# Install the Chapter 1 demo infrastructure on an existing OpenShift AI platform.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'EOF'
Usage: ./chapter-1/install.sh [options]
  --check-only             Same as ./chapter-1/check-prereqs.sh
  --scale-down-demo-model  Stop the Demo Platform's default Llama deployment
  --gpu-time-slicing       Configure two shared GPU slots using the supplied L4 config
  --with-models            Submit Granite and TinyLlama after verification
  --help                   Show this help

Requires OpenShift 4.20.x, OpenShift AI 3.5.x, cluster-admin access,
GPU drivers, a default StorageClass, and registry access. Installs demo
infrastructure, including PostgreSQL with disposable storage/example credentials.
EOF
}

check_only=false
scale_down=false
time_slicing=false
with_models=false
for arg in "$@"; do
  case "$arg" in
    --check-only) check_only=true ;;
    --scale-down-demo-model) scale_down=true ;;
    --gpu-time-slicing) time_slicing=true ;;
    --with-models) with_models=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if $check_only && { $scale_down || $time_slicing || $with_models; }; then
  echo '--check-only cannot be combined with options that change the cluster' >&2
  exit 1
fi
if $check_only; then
  exec bash chapter-1/check-prereqs.sh
fi

source chapter-1/check-prereqs.sh
stage='local prerequisites'
trap 'echo "Chapter 1 stopped during: $stage (line $LINENO). Resolve the error above, then rerun the script." >&2' ERR
check_local_tools
check_platform

step 'GPU prerequisites'
if $scale_down; then
  demo_deployment=$(oc get deployment llama-32-3b-instruct-predictor -n my-first-model --ignore-not-found -o name)
  if [[ -n "$demo_deployment" ]]; then
    oc scale deployment llama-32-3b-instruct-predictor -n my-first-model --replicas=0
    oc rollout status deployment/llama-32-3b-instruct-predictor -n my-first-model --timeout=300s
  fi
fi
if $time_slicing; then
  oc get clusterpolicy gpu-cluster-policy
  oc apply -f chapter-1/gpu-time-slicing.yml
  oc patch clusterpolicy gpu-cluster-policy --type=merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"l4"}}}}'
  oc rollout status daemonset/nvidia-device-plugin-daemonset -n nvidia-gpu-operator --timeout=300s
fi
check_gpus

step 'Connectivity Link and Kuadrant'
if [[ $(jq 'length' <<< "$rhcl") == 0 ]]; then
  oc apply -f chapter-1/0-connectivity-link.yml
  rhcl_namespace=kuadrant-system
  rhcl_subscription=rhcl-operator
else
  rhcl_namespace=$(jq -r '.[0].metadata.namespace' <<< "$rhcl")
  rhcl_subscription=$(jq -r '.[0].metadata.name' <<< "$rhcl")
  echo "Reusing RHCL subscription $rhcl_namespace/$rhcl_subscription"
fi
oc wait "subscription/$rhcl_subscription" -n "$rhcl_namespace" --for=jsonpath='{.status.installedCSV}' --timeout=600s
rhcl_csv=$(oc get subscription "$rhcl_subscription" -n "$rhcl_namespace" -o jsonpath='{.status.installedCSV}')
oc wait csv "$rhcl_csv" -n "$rhcl_namespace" --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
bash chapter-1/preflight-kuadrant.sh
oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -
oc apply -f chapter-1/1-kuadrant.yml
oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=600s

step 'KServe and llm-d'
oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"managementState":"Managed"}}}}'
oc wait datasciencecluster/default-dsc --for=condition=KserveReady --timeout=600s
oc wait datasciencecluster/default-dsc --for=condition=KserveLLMInferenceServiceDependencies --timeout=600s
oc get crd llminferenceservices.serving.kserve.io inferencepools.inference.networking.k8s.io

step 'Gateway and Authorino TLS'
oc apply -f chapter-1/2-gw-service-tls-cm.yml
# Create the Route first so the HTTPS listeners are distinct on initial apply.
# OpenShift assigns its hostname before the Gateway's backend Service exists.
envsubst '$GW_CLASS' < chapter-1/4-route.yml | oc apply -f -
export ROUTE_HOST
ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
[[ -n "$ROUTE_HOST" ]] || die 'The inference Route has no hostname'
envsubst '$GW_CLASS $ROUTE_HOST' < chapter-1/3-gateway.yml | oc apply -f -
oc wait --for=create deployment/authorino -n kuadrant-system --timeout=300s
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
oc annotate service authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
oc wait --for=create secret/authorino-server-cert -n kuadrant-system --timeout=300s
oc patch authorino authorino -n kuadrant-system --type=merge \
  -p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
oc wait authorino/authorino -n kuadrant-system --for=condition=Ready --timeout=300s
oc rollout status deployment/authorino -n kuadrant-system --timeout=300s
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=600s

step 'MaaS database and user workload monitoring'
oc apply -f chapter-1/5-maas-db.yml
oc rollout status deployment/maas-postgres -n redhat-ods-applications --timeout=300s
monitoring=$(oc get configmap cluster-monitoring-config -n openshift-monitoring --ignore-not-found -o json)
if [[ -z "$monitoring" ]]; then
  oc apply -f chapter-1/6-user-workload-monitoring.yml
else
  # Change only the top-level enableUserWorkload key; preserve other settings.
  config=$(jq -r '.data["config.yaml"] // ""' <<< "$monitoring" | awk '
    /^enableUserWorkload[[:space:]]*:/ { if (!found++) print "enableUserWorkload: true"; next }
    { print }
    END { if (!found) print "enableUserWorkload: true" }')
  oc patch configmap cluster-monitoring-config -n openshift-monitoring --type=merge \
    -p "$(jq -n --arg config "$config" '{data:{"config.yaml":$config}}')"
fi
oc wait --for=create statefulset/prometheus-user-workload -n openshift-user-workload-monitoring --timeout=600s
oc rollout status statefulset/prometheus-user-workload -n openshift-user-workload-monitoring --timeout=600s

step 'MaaS API and telemetry'
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"aigateway":{"managementState":"Managed","modelsAsAService":{"managementState":"Managed"}}}}}'
# This also allows time for the operator to register the MaaS APIs.
oc wait datasciencecluster/default-dsc --for=condition=ModelsAsAServiceReady --timeout=600s
oc wait --for=create maastenantconfig/default-tenant -n models-as-a-service --timeout=600s
oc wait maastenantconfig/default-tenant -n models-as-a-service --for=condition=Ready --timeout=600s
oc wait --for=create deployment/maas-api -n redhat-ai-gateway-infra --timeout=300s
oc rollout status deployment/maas-api -n redhat-ai-gateway-infra --timeout=600s
oc patch kuadrant kuadrant -n kuadrant-system --type=merge -p '{"spec":{"observability":{"enable":true}}}'
# Preserve any user/group capture enabled by the observability setup on a rerun.
oc patch maastenantconfig default-tenant -n models-as-a-service --type=merge \
  -p '{"spec":{"telemetry":{"enabled":true,"metrics":{"captureOrganization":true,"captureModelUsage":true}}}}'
oc wait --for=create telemetrypolicy/maas-telemetry -n openshift-ingress --timeout=300s
oc wait telemetrypolicy/maas-telemetry -n openshift-ingress --for=condition=Enforced --timeout=600s
oc rollout restart deployment -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
oc rollout status deployment -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --timeout=300s
oc wait --for=create podmonitor/kuadrant-limitador-monitor -n kuadrant-system --timeout=300s

step 'Dashboard and gateway hostname'
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"modelAsService":true,"genAiStudio":true,"observabilityDashboard":true}}}'
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=300s
oc wait route/openshift-ai-inference -n openshift-ingress --for=jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'=True --timeout=300s

step 'Final verification'
bash chapter-1/7-verify-maas.sh
echo "Inference endpoint: https://$ROUTE_HOST"
if $with_models; then
  step 'Start model downloads'
  oc wait authpolicy/maas-gateway-auth tokenratelimitpolicy/gateway-default-deny \
    -n openshift-ingress --for=condition=Enforced --timeout=300s
  oc create namespace ai-models --dry-run=client -o yaml | oc apply -f -
  oc apply -f chapter-1/granite-data-connection.yml \
    -f chapter-1/tinyllama-data-connection.yml
  oc apply -f chapter-1/granite-inference-service.yml \
    -f chapter-1/tinyllama-inference-service.yml
  oc get llminferenceservice granite-2b tinyllama -n ai-models
  echo 'Chapter 1 complete. Both model services submitted; continue with Chapter 2.'
else
  echo 'Chapter 1 complete. Continue with starting the model downloads in chapter-1/README.md.'
fi
