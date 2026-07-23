# Chapter 5: Observability, Rate Limiting & Chargeback

The platform is live — now make it observable. In this chapter you'll:

1. Enable telemetry for token tracking
2. Run a load generator to trigger rate limits
3. Query metrics for chargeback
4. Deploy a Perses dashboard in the OpenShift console

## Step 1: Enable Telemetry

By default, OpenShift AI does **not** scrape rate-limiting or token metrics. Enable them before generating traffic.

### Enable Kuadrant Observability

This creates a `PodMonitor` that tells Prometheus to scrape Limitador for rate-limiting metrics:

```bash
oc patch kuadrant kuadrant -n kuadrant-system \
  --type merge \
  -p '{"spec":{"observability":{"enable":true}}}'
```

Verify:

```bash
oc get podmonitor kuadrant-limitador-monitor -n kuadrant-system
```

### Enable Tenant Telemetry

This enables token consumption and request count metrics on the MaaS gateway:

```bash
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  --type merge \
  -p '{
    "spec": {
      "telemetry": {
        "enabled": true,
        "metrics": {
          "captureOrganization": true,
          "captureUser": false,
          "captureGroup": false,
          "captureModelUsage": true
        }
      }
    }
  }'
```

> **Note:** `captureUser` and `captureGroup` are `false` by default. Enabling user-level tracking on large clusters increases metric cardinality significantly. Subscription-level aggregation is sufficient for chargeback.

## Step 2: Run the Load Generator

This Kubernetes Job sends repeated requests using `department-b`'s limited-plan key to intentionally trigger rate limiting.

### Store the API Key

```bash
export MAAS_API_KEY="sk-oai-..."  # your department-b key from Chapter 4

oc create secret generic department-b-api-key \
  --from-literal=key=$MAAS_API_KEY \
  -n ai-models
```

### Deploy the Script and Job

```bash
oc apply -f chapter-5/load-generator-configmap.yml
```

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
envsubst < chapter-5/load-generator-job.yml | oc apply -f -
```

### Watch the Rate Limiting

```bash
oc logs -f job/load-generator -n ai-models
```

You'll see `✅ Success` messages followed by `🛑 429 Rate Limit Hit` once the token quota is exhausted. The script uses exponential backoff via the `Retry-After` header.

### Tuning Limits (Optional)

If all 20 requests succeed without hitting a 429, tighten the limit:

```bash
oc patch maassubscription limited-plan -n models-as-a-service --type=json \
  -p='[{"op": "replace", "path": "/spec/modelRefs/1/tokenRateLimits/0/limit", "value": 500}]'
```

Then re-run:

```bash
oc delete job load-generator -n ai-models
envsubst < chapter-5/load-generator-job.yml | oc apply -f -
```

## Step 3: Query Metrics (Chargeback)

### Verify Prometheus Pipeline

```bash
oc exec -n openshift-monitoring sts/prometheus-k8s -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=authorized_calls' | jq
```

### OpenShift Metrics Console

Open the **OpenShift Web Console** → **Observe → Metrics** and run these PromQL queries:

| Query | What it shows |
|---|---|
| `authorized_hits` | Total tokens consumed (the billing metric) |
| `authorized_calls` | Total successful API requests |
| `limited_calls` | Rate limit rejections (429 responses) |

Export to CSV using the **Download** icon for chargeback reports.

## Step 4: Perses Dashboard

Instead of deploying a separate Grafana instance, we use [Perses](https://perses.dev/) — the cloud-native dashboard tool that ships with the Cluster Observability Operator (COO). Perses dashboards are Kubernetes CRDs: you manage them with `oc apply`, store them in Git, and control access via standard RBAC. The dashboards appear directly in the OpenShift console under **Observe → Dashboards (Perses)**.

### Install the Cluster Observability Operator

Install COO via OLM. This automatically deploys the Perses Operator and registers the Perses CRDs.

```bash
oc apply -f chapter-5/coo-subscription.yml
```

Wait for the operator to install:

```bash
CSV=$(oc get subscription cluster-observability-operator \
  -n openshift-cluster-observability-operator -o jsonpath='{.status.installedCSV}')
oc wait csv "$CSV" -n openshift-cluster-observability-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

Verify the Perses CRDs and operators are available:

```bash
oc get crds | grep perses
# persesdashboards.perses.dev
# persesdatasources.perses.dev
# persesglobaldatasources.perses.dev

oc get pods -n openshift-cluster-observability-operator
# observability-operator-...   1/1   Running
# perses-operator-...          1/1   Running
```

### Enable the Monitoring UIPlugin with Perses

Create a `UIPlugin` resource to enable the Perses UI in the OpenShift web console. This triggers creation of a Perses server instance and adds the **Observe → Dashboards (Perses)** menu item.

```bash
oc apply -f chapter-5/perses-ui-plugin.yml
```

Verify the UIPlugin is reconciled and the Perses server is running:

```bash
oc get uiplugin monitoring -o jsonpath='{.status.conditions[0].message}'
# Plugin reconciled successfully

oc get pods -n openshift-cluster-observability-operator -l app.kubernetes.io/name=perses
# perses-0   1/1   Running
```

> **Note:** After enabling the plugin, it may take a few minutes for the **Dashboards (Perses)** menu to appear in the OpenShift web console. A page refresh may be needed.

### Create a Global Thanos Querier Datasource

Connect Perses to the platform Thanos Querier so dashboards can query Prometheus metrics cluster-wide. This uses Kubernetes-native authentication — the Perses server's ServiceAccount authenticates to Thanos Querier using its projected token.

The manifest includes a `ClusterRoleBinding` that grants the Perses ServiceAccount the `cluster-monitoring-view` role, and a `PersesGlobalDatasource` that configures the connection.

```bash
oc apply -f chapter-5/perses-datasource.yml
```

Verify:

```bash
oc get persesglobaldatasources
# NAME                        AGE
# thanos-querier-datasource   ...
```

### Deploy the MaaS Overview Dashboard

Apply a `PersesDashboard` CR that visualises MaaS metrics. The dashboard is namespace-scoped and deployed to `ai-models`.

```bash
oc apply -f chapter-5/perses-dashboard.yml
```

This creates a dashboard with the following sections:

| Section | Panels | Metrics |
|---|---|---|
| **Summary** | Stat panels | `sum(authorized_hits)`, `sum(authorized_calls)`, `sum(limited_calls)` |
| **Token Consumption & Chargeback** | Bar chart + Time series | `sum(authorized_hits) by (app_id)`, `sum(rate(authorized_hits[$interval])) by (app_id)` |
| **Rate Limiting** | Time series charts | `sum(rate(authorized_calls[$interval]))` vs `sum(rate(limited_calls[$interval]))` |
| **Model Performance** | Time series chart | `histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[$interval])) by (le, model_name))` |

A `$interval` variable (1m / 5m / 15m) controls the rate window for all panels.

Verify:

```bash
oc get persesdashboards -n ai-models
# NAME            AGE
# maas-overview   ...
```

### Access the Dashboard

1. Open the **OpenShift Web Console**
2. Navigate to **Observe → Dashboards (Perses)**
3. Select the **ai-models** project from the namespace dropdown
4. Click **MaaS Overview**

Run the load generator again to see data flowing in real time.

> **Tip:** Since the dashboard is a Kubernetes CR, you can also edit it interactively in the OpenShift console — changes are saved back to the `PersesDashboard` resource. Or export and edit as YAML:
>
> ```bash
> oc get persesdashboard maas-overview -n ai-models -o yaml > my-dashboard.yaml
> # Edit, then re-apply
> oc apply -f my-dashboard.yaml
> ```

---

🎉 **Congratulations!** You now have a fully governed, observable AI platform with subscription-based access control, rate limiting, and chargeback capabilities — with dashboards managed as Kubernetes CRDs directly in the OpenShift console.
