# Chapter 5: Usage & Showback Dashboard (Technology Preview)

Use the dashboard embedded in OpenShift AI to compare aggregate token consumption by model and subscription. Our mapping is `standard-plan` → `department-a` / `CC-1001`, and `limited-plan` → `department-b` / `CC-2001`. The dashboard filters on subscriptions, not OpenShift group names.

> [!NOTE]
> MaaS showback is Technology Preview. It supports internal usage attribution and capacity planning; token metrics are not billing-grade metering or external invoices. This chapter uses the metrics-based administrator dashboard. The separate Loki-based pipeline and user-scoped dashboards are outside this walkthrough.

## Step 1: Enable the OpenShift AI Metrics Stack

Chapter 1 enabled user workload monitoring and gateway telemetry. The embedded Usage dashboard additionally queries the **OpenShift AI monitoring stack**, using metrics normalized by its OpenTelemetry collector.

The demo uses the built-in OpenShift AI dashboards throughout. Their backend dependencies are:

| Component | Purpose | Setup |
|---|---|---|
| **Cluster Observability Operator (COO)** | Manages the Prometheus and Perses resources used by AI observability | Install/reuse the operator below |
| **Red Hat build of OpenTelemetry** | Collects and normalizes gateway/model metrics for the AI monitoring pipeline | Install/reuse the operator below |
| **AI Prometheus / Thanos** | Stores and queries token, request, rejection, and model metrics | Created by the AI monitoring configuration below |
| **AI-managed Perses backend** (`data-science-perses` in `redhat-ods-monitoring`) | Serves the built-in dashboard definitions to the OpenShift AI UI | Created by the AI monitoring configuration below |
| **MaaS / Kuadrant telemetry** | Supplies consumption and rejection counters, with labels required by Usage | Chapter 1 plus Step 2 below |

COO and OpenTelemetry are still needed when using only the OpenShift AI UI. The additional OpenShift console `UIPlugin`, a second Perses server in COO's namespace, a custom `maas-overview` dashboard, and its datasource/RBAC are unnecessary for this demo. Tempo/tracing and Loki are also unnecessary for this metrics-based walkthrough.

Token-budget enforcement itself runs in the gateway and Kuadrant/Limitador, using the subscriptions and vLLM response usage configured in earlier chapters. The AI metrics stack displays that consumption and its `429` rejections; it does not enforce the budget.

Install Red Hat build of OpenTelemetry and the Cluster Observability Operator (COO). COO supplies the Perses backend used by the embedded dashboard. First check for existing installations:

```bash
oc get subscription -A | grep -E 'opentelemetry-product|cluster-observability-operator'
```

No matches are expected on a cluster without these operators. If either is already installed, reuse it and its installation namespace for the waits below; do not create duplicate Subscriptions or OperatorGroups. Otherwise apply:

```bash
oc apply -f chapter-5/0-opentelemetry-subscription.yml
oc apply -f chapter-5/1-coo-subscription.yml
```

Wait for each Subscription to report an installed CSV, then wait for installation:

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

Configure metrics after both operators are installed. This needs neither Tempo nor a traces configuration:

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

Wait for the metrics and Perses backends:

```bash
oc wait dscinitialization/default-dsci --for=condition=MonitoringStackAvailable --timeout=300s
oc wait dscinitialization/default-dsci --for=condition=PersesAvailable --timeout=300s
oc get pods -n redhat-ods-monitoring
oc get pvc -n redhat-ods-monitoring
oc get servicemonitor limitador-metrics -n redhat-ods-monitoring --show-labels
```

MaaS creates `limitador-metrics` with `monitoring.opendatahub.io/scrape=true`. The collector selects that monitor automatically. Do not also label the Chapter 1 Limitador PodMonitor for this collector: collecting the same counters twice can inflate totals.

The Prometheus (5 GiB) and Perses (1 GiB) PVCs must be `Bound`; a `Pending` claim needs a working default StorageClass. On the single-node validation cluster, an extra Alertmanager replica stayed `Pending` because of pod anti-affinity; the collector, Prometheus, Thanos, and Perses were healthy and Usage worked. Diagnose pending metrics/backend pods before generating demo traffic.

## Step 2: Enable the Labels Required by Usage

The shipped 3.5.1 dashboard queries `authorized_hits_total{user!=""}`. Chapter 1's aggregate telemetry keeps user labels disabled, so enable them **before** generating showback traffic:

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
oc get telemetrypolicy maas-telemetry -n openshift-ingress \
  -o jsonpath='{.spec.metrics.default.labels}{"\n"}'
```

Expected labels include `user`, `subscription`, and `model`. User labels increase metric cardinality and expose usernames to monitoring readers; enable them deliberately for this demo. They are required by this dashboard even when comparing aggregate subscription totals. Earlier traffic without a user label does not become visible retroactively.

Verify that the operator-managed Usage dashboard is available:

```bash
oc wait persesdashboard/dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  --for=condition=Available --timeout=120s
```

If it remains unavailable, inspect its conditions:

```bash
oc get persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  -o jsonpath='{.status.conditions}{"\n"}'
```

On the validation cluster, MaaS created the dashboard before the Perses server existed. Its condition retained an old `PersesBackendError` / connection-refused error after the server became healthy. Retrying reconciliation with an annotation resolved it:

```bash
oc annotate persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  tutorial.openshift-ai/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
oc wait persesdashboard/dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  --for=condition=Available --timeout=120s
```

## Step 3: Generate Comparable Usage

Keep both department API keys exported from Chapter 4:

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
: "${MAAS_API_KEY_A:?Set the department-a key saved in Chapter 4}"
: "${MAAS_API_KEY_B:?Set the department-b key from Chapter 4}"
```

If you lost either key, generate a replacement through **Gen AI studio → API keys** while your user belongs to the corresponding department. Select `standard-plan` for department-a and `limited-plan` for department-b. Keys retain the group snapshot from creation.

Create three usage series: department-a on Granite, and department-b on Granite and TinyLlama. First seed each series so monitoring can establish a counter baseline:

```bash
send_request() {
  curl -sS -k --max-time 60 -o /dev/null -w "$1 HTTP:%{http_code}\n" \
    https://$ROUTE_HOST/ai-models/$1/v1/chat/completions \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain Kubernetes in one sentence.\"}],\"max_tokens\":40,\"stream\":true}"
}

send_request granite-2b "$MAAS_API_KEY_A"
send_request granite-2b "$MAAS_API_KEY_B"
send_request tinyllama "$MAAS_API_KEY_B"
```

Expect `HTTP:200` for all three. Wait for the collector and Prometheus to scrape, then generate increments:

```bash
sleep 45
for i in $(seq 1 3); do
  send_request granite-2b "$MAAS_API_KEY_A"
  send_request granite-2b "$MAAS_API_KEY_B"
  send_request tinyllama "$MAAS_API_KEY_B"
done
export MAAS_API_KEY=$MAAS_API_KEY_B
```

Allow another 1–2 minutes for the collector, Prometheus, and dashboard refresh. If TinyLlama returns `429` from an earlier rate-limit experiment, restore its 1,000 tokens/minute limit using the command at the end of Chapter 6, then wait for the one-minute window to reset.

## Step 4: Explore the Embedded Dashboard

1. Log in to the **OpenShift AI dashboard** as an administrator.
2. Open **Observe & monitor → Dashboard → Usage**. Refresh the browser if the tab was created after you opened the page.
3. Choose a time period that includes your new traffic, such as **Last 30 minutes**, and click **Refresh**.
4. Review **Total tokens**, **Total requests**, **Total rate limited**, **Success rate**, and **Active users**.

![OpenShift AI Usage dashboard with model and subscription filters, token consumption, request counts, and rate-limit rejections](../img/maas-usage-overview.png)

*Example captured on OpenShift AI 3.5.1 using **Last 6 hours** to include the full demo. The screenshots include the rate-limit test from Chapter 6; before that test, zero rate-limit rejections are expected. Your totals will differ.*

5. In **Subscription**, select `standard-plan`. In **Model**, select `granite-2b`.
6. Switch Subscription to `limited-plan` and compare Granite and TinyLlama.
7. Set **View by** to **By subscription** to compare departments, then **By model** to compare model consumption. Reset filters to **All** when making an overall comparison.
8. Scroll down to the **Token consumption table** to inspect the user/subscription/model rows.

Expected nonzero combinations:

| Subscription | Department | Model |
|---|---|---|
| `standard-plan` | department-a | `granite-2b` |
| `limited-plan` | department-b | `granite-2b` |
| `limited-plan` | department-b | `tinyllama` |

![Token consumption grouped by subscription, with table rows for department-a on Granite and department-b on Granite and TinyLlama](../img/maas-usage-by-subscription.png)

*With **View by → By subscription** and filters set to **All**, the chart compares the two plans and the table shows all three subscription/model combinations. The TinyLlama row also shows the Chapter 6 rejections.*

The same admin user creates both keys in this tutorial, so **Active users can be 1** even though two departments have traffic. Counts are derived from sampled counter increases and can differ from the exact number of requests you sent. Initial counter values, scrape timing, and restarts affect the result.

## Step 5: Export and Verify Usage

Set **View by → By subscription** for department attribution, or **By model** for model comparison. Hover over or click the **Token consumption chart** panel, then click **Export time series data as CSV** in its top-right toolbar.

![Token consumption chart toolbar with the CSV download button at the far right](../img/maas-usage-csv-export.png)

*Use the download arrow at the far right of the chart header; the adjacent diagonal arrows change the panel view mode.*

The browser downloads `tokenConsumptionChart_data.csv`. It contains a `DateTime` column followed by series columns such as `{subscription=_limited-plan_}` or `{model=_tinyllama_}`. This exports the chart's sampled time series, not the user table. The selected filters determine which series appear. Check the headers and nonzero values before using the file for showback.

For an independent pipeline check, query the same Thanos endpoint used by the Usage dashboard:

```bash
oc exec -n openshift-user-workload-monitoring sts/prometheus-user-workload -c prometheus -- \
  curl -s 'http://thanos-querier-data-science-thanos-querier.redhat-ods-monitoring.svc.cluster.local:10902/api/v1/query?query=authorized_hits_total' \
  | jq '.data.result[] | {user: .metric.user, subscription: .metric.subscription, model: .metric.model, tokens: .value[1]}'
```

Expect entries with your OpenShift username (`admin` on the validation cluster), the two subscription names, and the relevant models. This query shows cumulative counters; the dashboard calculates increases over the selected time range. Raw user-workload Prometheus exposes `authorized_hits`, whereas the AI OpenTelemetry pipeline exposes `authorized_hits_total`. Querying the wrong metric name or monitoring instance can make a healthy pipeline look empty.

If the dashboard is still empty, verify the user label, `limitador-metrics` ServiceMonitor, collector readiness, and time range. Send a second round after the first scrape: `increase()` needs multiple samples. The default dashboard's token chart uses a two-hour increase window in 3.5.1; use the overview/table and selected time range when checking totals.

Proceed to [Chapter 6: Observability & Rate Limiting](../chapter-6/README.md) to demonstrate token-budget enforcement and inspect rejection counts and model performance in the built-in OpenShift AI dashboards.

References: [MaaS administration and showback](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service), [OpenShift AI observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-observability_managing-rhoai).
