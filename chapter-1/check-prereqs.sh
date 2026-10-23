#!/usr/bin/env bash
# Read-only prerequisite checks for Chapter 1.
# Usage: ./chapter-1/check-prereqs.sh
# Also sourced by install.sh.

step() { stage=$1; printf '\n=== %s ===\n' "$stage"; }
die() { echo "$*" >&2; exit 1; }

check_local_tools() {
  step 'Local tools'
  echo 'Required: oc (OpenShift 4.20 client, for oc wait --for=create), curl, jq, envsubst (gettext), Bash'
  for tool in oc curl jq envsubst; do
    command -v "$tool" >/dev/null || die "Required command not found: $tool"
  done
}

check_platform() {
  step 'Platform'
  echo 'Requires OpenShift 4.20.x, OpenShift AI 3.5.x, cluster-admin, default-dsc/default-dsci/default-gateway, and a default StorageClass'
  oc whoami
  [[ $(oc auth can-i '*' '*' --all-namespaces) == yes ]] || die 'Log in with cluster-admin access'
  oc get datasciencecluster default-dsc
  oc get dscinitialization default-dsci
  oc wait gatewayconfig/default-gateway --for=condition=Ready --timeout=300s
  ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
  rhoai_csv=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}')
  [[ -n "$rhoai_csv" ]] || die 'OpenShift AI is not installed yet'
  rhoai_version=$(oc get csv "$rhoai_csv" -n redhat-ods-operator -o jsonpath='{.spec.version}')
  rhoai_channel=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}')
  rhoai_approval=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.installPlanApproval}')
  dsc_release=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.release.version}')
  echo "OpenShift $ocp_version"
  echo "OpenShift AI $rhoai_version (CSV $rhoai_csv, channel ${rhoai_channel:-unknown}, approval ${rhoai_approval:-unknown})"
  echo "DSC release ${dsc_release:-unknown}"
  [[ "$ocp_version" == 4.20.* && "$rhoai_version" == 3.5.* ]] \
    || die "This tutorial targets OpenShift 4.20.x and OpenShift AI 3.5.x (found $ocp_version / $rhoai_version). Upgrade using https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/"
  oc wait csv "$rhoai_csv" -n redhat-ods-operator --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
  oc get storageclass -o json | jq -e 'any(.items[];
    .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
    .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")' >/dev/null \
    || die 'A default StorageClass is required for observability PVCs'
  export GW_CLASS
  GW_CLASS=$(oc get gatewayclass -o json | jq -er \
    '[.items[] | select(.spec.controllerName | startswith("openshift.io/gateway-controller")) | .metadata.name] | sort | first // empty') \
    || die 'No OpenShift GatewayClass found; complete the platform gateway setup first'
  oc wait "gatewayclass/$GW_CLASS" --for=condition=Accepted --timeout=300s

  rhcl=$(oc get subscription -A -o json | jq -c '[.items[] | select(.spec.name == "rhcl-operator")]')
  [[ $(jq 'length' <<< "$rhcl") -le 1 ]] || die 'Multiple RHCL subscriptions found; resolve the installation layout first'
  kuadrant_crd=$(oc get crd kuadrants.kuadrant.io --ignore-not-found -o name)
  if [[ -n "$kuadrant_crd" ]]; then
    other_kuadrants=$(oc get kuadrant -A -o json | jq -r '.items[] |
      select(.metadata.namespace != "kuadrant-system" or .metadata.name != "kuadrant") |
      "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$other_kuadrants" ]] || die "An existing Kuadrant instance needs administrator review before installing this demo: $other_kuadrants"
  fi
}

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

check_gpus() {
  echo 'Requires two free schedulable GPU slots. Occupied slots count as used; this counts Kubernetes reservations only.'
  free=$(free_gpus)
  if ${time_slicing:-false} || ${scale_down:-false}; then
    for ((attempt=0; attempt<60 && free<2; attempt++)); do
      sleep 5
      free=$(free_gpus)
    done
  fi
  echo "Unreserved GPU slots on schedulable nodes: $free"
  [[ "$free" -ge 2 ]] || die 'Two free GPU slots are required. Rerun the installer with --scale-down-demo-model (Demo Platform) and/or --gpu-time-slicing (one physical L4).'
}

print_unverified_notes() {
  cat <<'EOF'

Not verified by this script:
- Image-pull access to registry.redhat.io and quay.io
- GPU memory (tested on L4 24 GiB)
- At least 6 GiB on the default StorageClass for observability PVCs
- OpenShift AI dashboard reachable in a browser

Validated on OpenShift 4.20.42 / OpenShift AI 3.5.2, channel stable-3.x with Automatic approval.
Automatic approval follows the channel; it does not pin a minor version.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  stage='local prerequisites'
  trap 'echo "Prerequisite check stopped during: $stage (line $LINENO). Resolve the error above, then rerun." >&2' ERR
  check_local_tools
  check_platform
  step 'GPU'
  check_gpus
  echo
  echo 'Platform pre-check passed. Continue with ./chapter-1/install.sh and the flags for this cluster.'
  print_unverified_notes
fi
