#!/usr/bin/env bash
# Check dependency discovery before creating the Kuadrant instance.
set -euo pipefail

for crd in authorinos.operator.authorino.kuadrant.io limitadors.limitador.kuadrant.io dnsrecords.kuadrant.io; do
  oc wait --for=create "crd/$crd" --timeout=300s
  oc wait --for=condition=Established "crd/$crd" --timeout=300s
done

# Dependencies can be installed globally or alongside RHCL.
for deployment in limitador-operator-controller-manager dns-operator-controller-manager kuadrant-operator-controller-manager; do
  for ((attempt=0; attempt<60; attempt++)); do
    namespaces=$(oc get deployment -A -o json | jq -r --arg name "$deployment" \
      '.items[] | select(.metadata.name == $name) | .metadata.namespace')
    [[ -n "$namespaces" ]] && break
    sleep 5
  done
  if [[ -z "$namespaces" || "$namespaces" == *$'\n'* ]]; then
    echo "Expected one $deployment deployment; found namespaces: $namespaces" >&2
    exit 1
  fi
  oc rollout status "deployment/$deployment" -n "$namespaces" --timeout=300s
  if [[ "$deployment" == kuadrant-operator-controller-manager ]]; then
    operator_namespace=$namespaces
  fi
done

logs=$(oc logs deployment/kuadrant-operator-controller-manager -n "$operator_namespace" -c manager --tail=-1)
if grep -Eq '(authorino|limitador|dns) operator is not installed, skipping related watches and reconcilers' <<< "$logs"; then
  echo 'Refreshing Kuadrant dependency discovery before creating the instance'
  # OLM can revert rollout restart; replacing the pod preserves the managed template.
  oc delete pod -n "$operator_namespace" -l app=kuadrant,control-plane=controller-manager
  oc rollout status deployment/kuadrant-operator-controller-manager -n "$operator_namespace" --timeout=300s
fi

echo 'Kuadrant dependency pre-check passed'
