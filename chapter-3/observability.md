# Part 1 — Chapter 3, page 2: Configure observability

**Role:** cluster administrator. Complete [Chapter 3, page 1](README.md) (models registered and Ready) first.

The Chapter 1 installer does not install this stack. Complete this page even if you used the installer. Run commands from the repository root in the administrator Bash session.

## Step 1: Enable the OpenShift AI metrics stack

Chapter 1 enabled user workload monitoring and gateway telemetry. The Usage dashboard queries the **OpenShift AI monitoring stack**.

| Component | Purpose | Setup |
|---|---|---|
| **Cluster Observability Operator (COO)** | Prometheus and Perses used by AI observability | Install/reuse below |
| **Red Hat build of OpenTelemetry** | Collects and normalizes gateway/model metrics | Install/reuse below |
| **AI Prometheus / Thanos** | Stores token, request, rejection, and model metrics | Created by the monitoring patch below |
| **AI-managed Perses backend** (`data-science-perses` in `redhat-ods-monitoring`) | Serves built-in dashboard definitions | Created by the monitoring patch below |
| **MaaS / Kuadrant telemetry** | Consumption and rejection counters | Chapter 1 plus Step 2 |

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

## Step 2: Enable the labels required by Usage

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
``` User labels increase cardinality and expose usernames; this dashboard requires them even for aggregate totals. Earlier traffic without a user label does not appear retroactively.

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

## Verify

This is the final infrastructure checkpoint for Part 1. It repeats the readiness checks from page 1 so that a later rerun catches regressions:

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

Continue to page 3: [Create demonstration API keys](api-keys.md).
