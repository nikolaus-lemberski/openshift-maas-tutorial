# Part 1 — Chapter 3: Publish models, configure observability, and create API keys

**Role:** cluster administrator. Complete Chapter 1's [model downloads](../chapter-1/README.md#start-the-model-downloads) and [Chapter 2](../chapter-2/README.md) first.

This chapter finishes Part 1:

- **Steps 1–3:** register both models with MaaS, complete TinyLlama access, and wait for Ready.
- **Steps 4–6:** enable the metrics stack, user labels, and the Usage dashboard, then verify the platform.
- **Step 7:** create one API key per department, used throughout Part 2.

Run commands from the repository root in the administrator Bash session.

The manifests use `LLMInferenceService` with the MaaS Gateway, one GPU each, and `--enable-force-include-usage` so streamed responses also report token usage for rate limiting. Do not substitute a legacy `InferenceService` without MaaS integration.

## Step 1: Register both models with MaaS

Confirm both model services were submitted, then create their `MaaSModelRef` resources:

```bash
oc get llminferenceservice granite-2b tinyllama -n ai-models
oc apply -f chapter-3/granite-maas-model-ref.yml \
  -f chapter-3/tinyllama-maas-model-ref.yml
```

If either service is missing, return to [Start the model downloads](../chapter-1/README.md#start-the-model-downloads). Registration can reconcile while the backends are still initializing; readiness is checked below. Chapter 2's Granite subscriptions and authorization policies can now resolve their model reference.

## Step 2: Complete the access matrix

The updated manifests add TinyLlama to `limited-plan` and `limited-access`. Both resources must include the model: a subscription supplies its quota and an authorization policy permits gateway access.

| Department | Subscription | Granite tokens/min per user | TinyLlama tokens/min per user |
|---|---|---|---|
| `department-a` | `standard-plan` | 50,000 | No access |
| `department-b` | `limited-plan` | 2,000 | 1,000 |

```bash
oc apply -f chapter-3/subscriptions-updated.yml
oc apply -f chapter-3/auth-policies-updated.yml
```

## Step 3: Wait for readiness

Wait for image pulls and initialization if they did not finish during Chapter 2:

```bash
oc wait llminferenceservice/granite-2b llminferenceservice/tinyllama \
  -n ai-models --for=condition=Ready --timeout=1200s
oc wait maasmodelref/granite-2b maasmodelref/tinyllama \
  -n ai-models --for=condition=Ready --timeout=300s
oc wait maassubscription/standard-plan maassubscription/limited-plan \
  maasauthpolicy/standard-access maasauthpolicy/limited-access \
  -n models-as-a-service --for=condition=Ready --timeout=300s
oc get llminferenceservice -n ai-models
oc get maasmodelref -n ai-models
```

Expected: both services, both model references, and every governance wait succeed. On timeout:

```bash
oc get pods -n ai-models
oc get events -n ai-models --sort-by=.lastTimestamp
```

`Pending` often means insufficient GPU/CPU/memory. `ImagePullBackOff` is registry or pull-credential failure. Stop until the checks pass.

You can also watch **AI Hub → Models → Deployments** in `ai-models`.

## Step 4: Enable the OpenShift AI metrics stack

The Chapter 1 installer does not install this stack. Complete this step even if you used the installer.

Chapter 1 enabled user workload monitoring and gateway telemetry. The Usage dashboard queries the **OpenShift AI monitoring stack**.

| Component | Purpose | Setup |
|---|---|---|
| **Cluster Observability Operator (COO)** | Prometheus and Perses used by AI observability | Install/reuse below |
| **Red Hat build of OpenTelemetry** | Collects and normalizes gateway/model metrics | Install/reuse below |
| **AI Prometheus / Thanos** | Stores token, request, rejection, and model metrics | Created by the monitoring patch below |
| **AI-managed Perses backend** (`data-science-perses` in `redhat-ods-monitoring`) | Serves built-in dashboard definitions | Created by the monitoring patch below |
| **MaaS / Kuadrant telemetry** | Consumption and rejection counters | Chapter 1 plus Step 5 |

The OpenShift console `UIPlugin`, a second Perses server, a custom dashboard, Tempo, and Loki are not needed. Token-budget enforcement stays in the gateway; this stack only displays it.

Check for existing operators:

```bash
oc get subscription -A | grep -E 'opentelemetry-product|cluster-observability-operator'
```

If either is already installed, reuse it and its namespace. Otherwise apply:

```bash
oc apply -f chapter-1/opentelemetry-subscription.yml
oc apply -f chapter-1/coo-subscription.yml
```

```bash
oc wait subscription/opentelemetry-product -n openshift-opentelemetry-operator \
  --for=jsonpath='{.status.installedCSV}' --timeout=600s
OTEL_CSV=$(oc get subscription opentelemetry-product -n openshift-opentelemetry-operator -o jsonpath='{.status.installedCSV}')
oc wait csv "$OTEL_CSV" -n openshift-opentelemetry-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s

oc wait subscription/cluster-observability-operator -n openshift-cluster-observability-operator \
  --for=jsonpath='{.status.installedCSV}' --timeout=600s
COO_CSV=$(oc get subscription cluster-observability-operator -n openshift-cluster-observability-operator -o jsonpath='{.status.installedCSV}')
oc wait csv "$COO_CSV" -n openshift-cluster-observability-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

Configure metrics (no Tempo or traces):

```bash
oc patch dscinitialization default-dsci --type=merge -p '{
  "spec": {
    "monitoring": {
      "managementState": "Managed",
      "namespace": "redhat-ods-monitoring",
      "metrics": {
        "replicas": 1,
        "storage": {"size": "5Gi", "retention": "14d"}
      }
    }
  }
}'
```

```bash
oc wait dscinitialization/default-dsci --for=condition=MonitoringStackAvailable --timeout=300s
oc wait dscinitialization/default-dsci --for=condition=PersesAvailable --timeout=300s
for obj in pvc/prometheus-data-science-monitoringstack-db-prometheus-data-science-monitoringstack-0 \
  pvc/storage-data-science-perses-0 \
  pod/prometheus-data-science-monitoringstack-0 pod/data-science-perses-0; do
  oc wait --for=create "$obj" -n redhat-ods-monitoring --timeout=300s
done
oc wait pvc prometheus-data-science-monitoringstack-db-prometheus-data-science-monitoringstack-0 \
  storage-data-science-perses-0 \
  -n redhat-ods-monitoring --for=jsonpath='{.status.phase}'=Bound --timeout=300s
oc wait pod/prometheus-data-science-monitoringstack-0 pod/data-science-perses-0 \
  -n redhat-ods-monitoring --for=condition=Ready --timeout=300s
oc get pods -n redhat-ods-monitoring
oc get pvc -n redhat-ods-monitoring
oc get servicemonitor limitador-metrics -n redhat-ods-monitoring --show-labels
```

The DSCI conditions can become True before the Prometheus and Perses PVCs and pods exist, and they can stay True after a previous enable/disable. `oc wait` on a missing object returns NotFound immediately, and `oc wait --for=create` with several names fails the same way when none exist yet, so the loop waits for each object separately. MaaS creates `limitador-metrics` with `monitoring.opendatahub.io/scrape=true`. Do not also label the Chapter 1 Limitador PodMonitor for this collector.

Prometheus (5 GiB) and Perses (1 GiB) PVCs must be `Bound`. On the single-node validation cluster an extra Alertmanager replica stayed `Pending` because of anti-affinity; Usage still worked. Diagnose pending metrics/backend pods before generating traffic.

## Step 5: Enable the labels required by Usage

The 3.5 Usage dashboard queries `authorized_hits_total{user!=""}`. Enable user labels **before** showback traffic:

```bash
oc patch maastenantconfig default-tenant -n models-as-a-service --type=merge -p '{
  "spec": {
    "telemetry": {
      "enabled": true,
      "metrics": {
        "captureOrganization": true,
        "captureUser": true,
        "captureGroup": false,
        "captureModelUsage": true
      }
    }
  }
}'
oc wait telemetrypolicy/maas-telemetry -n openshift-ingress \
  --for=jsonpath='{.spec.metrics.default.labels.user}' --timeout=120s
oc get telemetrypolicy maas-telemetry -n openshift-ingress \
  -o jsonpath='{.spec.metrics.default.labels}{"\n"}' | jq -c keys
```

The controller adds the `user` label a few seconds after the patch; the wait covers that delay. Expected:

```
["cost_center","model","organization_id","subscription","user"]
```

User labels increase cardinality and expose usernames; this dashboard requires them even for aggregate totals. Earlier traffic without a user label does not appear retroactively.

```bash
oc wait persesdashboard/dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  --for=condition=Available --timeout=120s
```

If it stays unavailable:

```bash
oc get persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  -o jsonpath='{.status.conditions}{"\n"}'
```

If MaaS created the dashboard before Perses started, an old `PersesBackendError` can stick. Retrigger reconciliation:

```bash
oc annotate persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  tutorial.openshift-ai/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
oc wait persesdashboard/dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  --for=condition=Available --timeout=120s
```

## Step 6: Verify the platform

This is the final infrastructure checkpoint for Part 1. It repeats the Step 3 readiness checks so that a later rerun, for example before a presentation, catches regressions:

```bash
./chapter-1/7-verify-maas.sh
oc wait llminferenceservice/granite-2b llminferenceservice/tinyllama \
  -n ai-models --for=condition=Ready --timeout=120s
oc wait maasmodelref/granite-2b maasmodelref/tinyllama \
  -n ai-models --for=condition=Ready --timeout=120s
oc wait maassubscription/standard-plan maassubscription/limited-plan \
  maasauthpolicy/standard-access maasauthpolicy/limited-access \
  -n models-as-a-service --for=condition=Ready --timeout=120s
echo 'MaaS gateway:'
oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='https://{.spec.host}{"\n"}'
echo 'OpenShift AI dashboard:'
oc get ingresses.config.openshift.io cluster -o jsonpath='https://rh-ai.{.spec.domain}{"\n"}'
```

Every check must pass. The dashboard URL matches the 3.5 `rh-ai.apps.<cluster-domain>` form; you can also copy it from the OpenShift application launcher. Keep the gateway hostname, dashboard URL, and any required CA certificate; see [client TLS](../chapter-1/README.md#client-tls).

## Step 7: Create demonstration API keys

Chapter 2 added you to both department groups. Create one API key per subscription. Each key keeps the plan you name here, so this terminal can demonstrate both departments without changing groups. The Usage dashboard can show one active user; the two subscriptions still appear separately.

Keep this terminal open through Chapters 4–6: the keys live only in its environment variables. Configure [client TLS](../chapter-1/README.md#client-tls) before creating keys.

`chapter-3/create-api-key.sh` does the work for one department:

1. Adds you to the department group (harmless if Chapter 2 already did).
2. Waits until MaaS lists that department's plan. Group changes can take about a minute to reach MaaS.
3. Revokes an active key with the same name, because key names must be unique.
4. Creates a one-day key and prints its metadata.

The plaintext key is returned only once. The script prints `export` lines for `ROUTE_HOST`, the key, and its ID; `eval` loads them into this shell. Create the department-a key (`standard-plan`, Granite only) and the department-b key (`limited-plan`, Granite and TinyLlama):

```bash
eval "$(./chapter-3/create-api-key.sh department-a)"
eval "$(./chapter-3/create-api-key.sh department-b)"
```

Expected: each command prints `Creating key department-a-test on standard-plan` or `Creating key department-b-test on limited-plan`, followed by JSON whose `subscription` matches and whose `expiresAt` is about one day from now. Confirm both keys are loaded:

```bash
echo "$MAAS_KEY_ID_A $MAAS_KEY_ID_B"
```

Expected: two key IDs. If a key is lost (for example, the terminal was closed) or expires, rerun its `eval` command in the new terminal. Later chapters repeat that command where they need it.

Part 1 is complete. Continue with [Chapter 4](../chapter-4/README.md) in this terminal.

## Cleanup

Run this only after Chapters 4–6 and any presentations. Restore the [normal TinyLlama quota](../chapter-6/README.md#step-4-restore-the-demo-quota) after rate-limit demonstrations. Keep the keys until the last presentation, then revoke both:

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
