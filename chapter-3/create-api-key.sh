#!/usr/bin/env bash
# Create (or recreate) the one-day demonstration API key for one department.
# Prints only export lines on stdout, so load the key into the current shell with:
#   eval "$(./chapter-3/create-api-key.sh department-a)"
# Progress and errors go to stderr. An existing active key with the same name is revoked first.
set -euo pipefail

case "${1:-}" in
  department-a) SUFFIX=A; PLAN=standard-plan ;;
  department-b) SUFFIX=B; PLAN=limited-plan ;;
  *) echo "Usage: eval \"\$($0 department-a|department-b)\"" >&2; exit 1 ;;
esac
GROUP=$1
KEY_NAME=$GROUP-test

log() { printf '%s\n' "$*" >&2; }

ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)
USER_NAME=$(oc whoami)
API=https://$ROUTE_HOST/maas-api/v1

log "Ensuring $USER_NAME is in $GROUP"
oc adm groups add-users "$GROUP" "$USER_NAME" >&2

log "Waiting for MaaS to list $PLAN (group changes can take about a minute)"
for attempt in $(seq 1 24); do
  if curl -fsS --max-time 60 -H "Authorization: Bearer $TOKEN" "$API/models" \
      | jq -e --arg plan "$PLAN" '[.data[].subscriptions[]?.name] | index($plan)' >/dev/null; then
    break
  fi
  if [ "$attempt" -eq 24 ]; then
    log "MaaS still does not list $PLAN after 2 minutes. Check that the subscription is Ready and retry."
    exit 1
  fi
  sleep 5
done

for id in $(curl -fsS --max-time 60 -X POST "$API/api-keys/search" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
    | jq -r --arg name "$KEY_NAME" '.data // [] | .[] | select(.name == $name and .status == "active") | .id'); do
  log "Revoking existing key $KEY_NAME ($id)"
  curl -fsS --max-time 60 -X DELETE "$API/api-keys/$id" -H "Authorization: Bearer $TOKEN" >/dev/null
done

log "Creating key $KEY_NAME on $PLAN"
RESPONSE=$(curl -sS --fail-with-body --max-time 60 -X POST "$API/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$KEY_NAME\",\"subscription\":\"$PLAN\",\"expiresIn\":\"1d\"}") || {
  log "Key creation failed: $RESPONSE"
  exit 1
}
jq '{id, name, subscription, expiresAt}' <<< "$RESPONSE" >&2

printf 'export ROUTE_HOST=%q\n' "$ROUTE_HOST"
printf 'export MAAS_API_KEY_%s=%q\n' "$SUFFIX" "$(jq -r .key <<< "$RESPONSE")"
printf 'export MAAS_KEY_ID_%s=%q\n' "$SUFFIX" "$(jq -r .id <<< "$RESPONSE")"
