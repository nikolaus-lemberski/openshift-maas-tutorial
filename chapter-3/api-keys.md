# Part 1 — Chapter 3, page 3: Create demonstration API keys

**Role:** cluster administrator. Complete [Configure observability](observability.md) first.

Chapter 2 added you to both department groups. Create one API key per subscription. Each key keeps the plan you name here, so this terminal can demonstrate both departments without changing groups. The Usage dashboard can show one active user; the two subscriptions still appear separately.

## Create both keys

Use Bash from the repository root. Keep this terminal open through Chapters 4–6: the keys live only in its environment variables. Configure [client TLS](../chapter-1/README.md#client-tls) before curl calls.

The group commands repeat Chapter 2 and are harmless if you are already a member. They make this page safe to rerun, for example before a later presentation.

```bash
set -o pipefail
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
oc adm groups add-users department-a "$(oc whoami)"
oc adm groups add-users department-b "$(oc whoami)"
oc whoami
```

MaaS can take about a minute to see group changes. Confirm both plans are listed:

```bash
curl -fsS --max-time 60 -H "Authorization: Bearer $(oc whoami -t)" \
  https://$ROUTE_HOST/maas-api/v1/models \
  | jq -r '.data[].subscriptions[]?.name' | sort -u
```

Expected:

```
limited-plan
standard-plan
```

If a name is missing, wait a minute and repeat that curl. Do not create keys until both names appear. A `400` from key creation usually means MaaS has not seen the group membership yet.

Create a one-day key for department-a (`standard-plan`, Granite only). The plaintext key is returned only once; store it in the shell and print metadata:

```bash
MAAS_KEY_RESPONSE=$(curl -sS --fail-with-body --max-time 60 -X POST \
  https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H 'Content-Type: application/json' \
  -d '{"name":"department-a-test","subscription":"standard-plan","expiresIn":"1d"}')
export MAAS_API_KEY_A=$(printf '%s' "$MAAS_KEY_RESPONSE" | jq -r .key)
export MAAS_KEY_ID_A=$(printf '%s' "$MAAS_KEY_RESPONSE" | jq -r .id)
printf '%s' "$MAAS_KEY_RESPONSE" | jq '{id, name, subscription, expiresAt}'
unset MAAS_KEY_RESPONSE
```

Expected: `subscription` is `standard-plan`, and `expiresAt` is about one day from now. `expirationDate` can be null on create.

Create a one-day key for department-b (`limited-plan`, Granite and TinyLlama):

```bash
MAAS_KEY_RESPONSE=$(curl -sS --fail-with-body --max-time 60 -X POST \
  https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H 'Content-Type: application/json' \
  -d '{"name":"department-b-test","subscription":"limited-plan","expiresIn":"1d"}')
export MAAS_API_KEY_B=$(printf '%s' "$MAAS_KEY_RESPONSE" | jq -r .key)
export MAAS_KEY_ID_B=$(printf '%s' "$MAAS_KEY_RESPONSE" | jq -r .id)
printf '%s' "$MAAS_KEY_RESPONSE" | jq '{id, name, subscription, expiresAt}'
unset MAAS_KEY_RESPONSE
```

Expected: `subscription` is `limited-plan`. If curl reports `400` after both plans were listed, that key name may already exist. Revoke `department-a-test` or `department-b-test` in **Gen AI Studio → API Keys** and retry.

If a key is lost (for example, the terminal was closed) or expires, revoke the old key by name in **Gen AI Studio → API Keys**, because key names must be unique. Then rerun that key's create command.

Part 1 is complete. Continue with [Chapter 4](../chapter-4/README.md) in this terminal.

## Cleanup

Restore the [normal TinyLlama quota](../chapter-6/README.md#step-4-restore-the-demo-quota) after rate-limit demonstrations. Keep the keys until the last presentation, then revoke both:

```bash
curl -sS --fail-with-body --max-time 60 -X DELETE \
  https://$ROUTE_HOST/maas-api/v1/api-keys/$MAAS_KEY_ID_A \
  -H "Authorization: Bearer $(oc whoami -t)" | jq -c '{name, status}'
curl -sS --fail-with-body --max-time 60 -X DELETE \
  https://$ROUTE_HOST/maas-api/v1/api-keys/$MAAS_KEY_ID_B \
  -H "Authorization: Bearer $(oc whoami -t)" | jq -c '{name, status}'
```

Expected:

```
{"name":"department-a-test","status":"revoked"}
{"name":"department-b-test","status":"revoked"}
```

Confirm both revoked keys are rejected:

```bash
curl -sS --max-time 60 -o /dev/null -w 'Department A HTTP:%{http_code}\n' \
  https://$ROUTE_HOST/maas-api/v1/models -H "Authorization: Bearer $MAAS_API_KEY_A"
curl -sS --max-time 60 -o /dev/null -w 'Department B HTTP:%{http_code}\n' \
  https://$ROUTE_HOST/maas-api/v1/models -H "Authorization: Bearer $MAAS_API_KEY_B"
```

Expected: **403** for both. If a DELETE failed, revoke the named keys in **Gen AI Studio → API Keys**, then repeat the checks.

```bash
unset MAAS_API_KEY MAAS_API_KEY_A MAAS_API_KEY_B MAAS_KEY_ID_A MAAS_KEY_ID_B
```
