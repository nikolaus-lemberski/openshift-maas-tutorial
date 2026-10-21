#!/usr/bin/env bash
# Install the Chapter 1 demo infrastructure on an existing OpenShift AI platform.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'EOF'
Usage: ./chapter-1/install.sh [options]
  --check-only             Check platform prerequisites without changing the cluster
  --scale-down-demo-model  Stop the Demo Platform's default Llama deployment
  --gpu-time-slicing       Configure two shared GPU slots using the supplied L4 config
  --help                   Show this help

Requires OpenShift 4.20.x, OpenShift AI 3.5.x, cluster-admin access,
GPU drivers, a default StorageClass, and registry access. Installs demo
infrastructure, including PostgreSQL with disposable storage/example credentials.
EOF
}

check_only=false
scale_down=false
time_slicing=false
for arg in "$@"; do
  case "$arg" in
    --check-only) check_only=true ;;
    --scale-down-demo-model) scale_down=true ;;
    --gpu-time-slicing) time_slicing=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if $check_only && { $scale_down || $time_slicing; }; then
  echo '--check-only cannot be combined with options that change GPU workloads' >&2
  exit 1
fi

stage='local prerequisites'
trap 'echo "Chapter 1 stopped during: $stage (line $LINENO). Resolve the error above, then rerun the script." >&2' ERR
step() { stage=$1; printf '\n=== %s ===\n' "$stage"; }
die() { echo "$*" >&2; exit 1; }

for tool in oc curl jq envsubst; do
  command -v "$tool" >/dev/null || die "Required command not found: $tool"
done

step 'Platform prerequisites'
oc whoami
[[ $(oc auth can-i '*' '*' --all-namespaces) == yes ]] || die 'Log in with cluster-admin access'
oc get datasciencecluster default-dsc
oc get dscinitialization default-dsci
oc wait gatewayconfig/default-gateway --for=condition=Ready --timeout=300s
ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
rhoai_csv=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}')
[[ -n "$rhoai_csv" ]] || die 'OpenShift AI is not installed yet'
rhoai_version=$(oc get csv "$rhoai_csv" -n redhat-ods-operator -o jsonpath='{.spec.version}')
echo "OpenShift $ocp_version; OpenShift AI $rhoai_version"
[[ "$ocp_version" == 4.20.* && "$rhoai_version" == 3.5.* ]] || die 'This installer targets OpenShift 4.20.x and OpenShift AI 3.5.x'
oc wait csv "$rhoai_csv" -n redhat-ods-operator --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc get storageclass -o json | jq -e 'any(.items[];
  .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
  .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")' >/dev/null \
  || die 'A default StorageClass is required for Chapter 5'
export GW_CLASS
GW_CLASS=$(oc get gatewayclass -o json | jq -er \
  '[.items[] | select(.spec.controllerName | startswith("openshift.io/gateway-controller")) | .metadata.name] | sort | first // empty') \
  || die 'No OpenShift GatewayClass found; complete the platform gateway setup first'
oc wait "gatewayclass/$GW_CLASS" --for=condition=Accepted --timeout=300s

# Reject ambiguous existing operator installations before making changes.
rhcl=$(oc get subscription -A -o json | jq -c '[.items[] | select(.spec.name == "rhcl-operator")]')
[[ $(jq 'length' <<< "$rhcl") -le 1 ]] || die 'Multiple RHCL subscriptions found; resolve the installation layout first'
kuadrant_crd=$(oc get crd kuadrants.kuadrant.io --ignore-not-found -o name)
if [[ -n "$kuadrant_crd" ]]; then
  other_kuadrants=$(oc get kuadrant -A -o json | jq -r '.items[] |
    select(.metadata.namespace != "kuadrant-system" or .metadata.name != "kuadrant") |
    "\(.metadata.namespace)/\(.metadata.name)"')
  [[ -z "$other_kuadrants" ]] || die "An existing Kuadrant instance needs administrator review before installing this demo: $other_kuadrants"
fi

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

# Count only Ready, uncordoned nodes without scheduling taints. Subtract
# scheduled requests (including init containers) and pending GPU requests.
free_gpus() {
  local nodes requests
  nodes=$(oc get nodes -o json | jq -c '[.items[] |
    select(.spec.unschedulable != true) |
    select(any(.status.conditions[]; .type == "Ready" and .status == "True")) |
    select(all(.spec.taints[]?; .effect != "NoSchedule" and .effect != "NoExecute")) |
    {name: .metadata.name, capacity: ((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber)}]')
  requests=$(oc get pods -A -o json | jq -c '[.items[] |
    select(.status.phase != "Succeeded" and .status.phase != "Failed") |
    {node: (.spec.nodeName // ""), gpu: ([
      ([.spec.containers[]? | (.resources.requests["nvidia.com/gpu"] // .resources.limits["nvidia.com/gpu"] // "0") | tonumber] | add // 0),
      (.spec.initContainers[]? | (.resources.requests["nvidia.com/gpu"] // .resources.limits["nvidia.com/gpu"] // "0") | tonumber)
    ] | max)}]')
  jq -nr --argjson nodes "$nodes" --argjson requests "$requests" '
    ([$nodes[] | . as $n |
      ([$requests[] | select(.node == $n.name) | .gpu] | add // 0) as $used |
      [0, ($n.capacity - $used)] | max] | add // 0) -
    ([$requests[] | select(.node == "") | .gpu] | add // 0)'
}
free=$(free_gpus)
# The device plugin advertises shared slots asynchronously after its restart.
if $time_slicing || $scale_down; then
  for ((attempt=0; attempt<60 && free<2; attempt++)); do
    sleep 5
    free=$(free_gpus)
  done
fi
echo "Unreserved GPU slots on schedulable nodes: $free"
[[ "$free" -ge 2 ]] || die 'Two free GPU slots are required. Free other GPU workloads, or use the explicit demo-model/time-slicing options; see Chapter 1.'
if $check_only; then
  echo 'Platform pre-check passed. Run without --check-only to install Chapter 1.'
  exit 0
fi

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
# Preserve any user/group capture enabled in later chapters on a rerun.
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
echo 'Chapter 1 complete. Continue with chapter-2/README.md.'
