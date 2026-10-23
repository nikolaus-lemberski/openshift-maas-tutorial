# Part 2 — Chapter 6: Operate token budgets

**Role:** AI ops administrator with cluster-admin access. Complete [Chapter 5](../chapter-5/README.md) first.

Demonstrate token-budget enforcement in the same Usage UI from Chapter 5:

1. Verify telemetry
2. Tighten TinyLlama and demonstrate HTTP `429`
3. Compare consumption and rejections
4. Restore the demo quota
5. Explore model performance dashboards

## Before you begin

Use the same terminal as Chapters 4–5. Inference uses the department-b key from [creating demonstration API keys](../chapter-3/api-keys.md):

```bash
export MAAS_API_KEY=$MAAS_API_KEY_B
```

If that key was lost, expired, or revoked, recreate the `limited-plan` key in [Create demonstration API keys](../chapter-3/api-keys.md). A subscription-resolution error means MaaS does not see your `department-b` group membership; wait about a minute after adding the group, then create a fresh key.

## Step 1: Verify telemetry

Chapter 1 and [Configure observability](../chapter-3/observability.md) enabled Kuadrant observability, tenant telemetry, and user labels on the gateway. Confirm the resources are still present before generating traffic:

```bash
oc get podmonitor kuadrant-limitador-monitor -n kuadrant-system
oc get telemetrypolicy maas-telemetry -n openshift-ingress
```

If either resource is missing, re-run [MaaS telemetry](../chapter-1/README.md#maas-telemetry) from Chapter 1 and restart the gateway. Then reapply the [user-label configuration](../chapter-3/observability.md#step-2-enable-the-labels-required-by-usage) so the Usage dashboard continues to receive labeled traffic.

Open **OpenShift AI → Observe & monitor → Dashboard → Usage** before the test. Select **Last 30 minutes**, the `limited-plan` subscription, and **Model → All**. Refresh and note the current **Total tokens** and **Total rate limited** values so you can compare them after the burst.

## Step 2: Trigger rate limiting

Each `MaaSSubscription` defines a per-user, per-model **token budget**. Keys for the same user share it; a new key does not reset it. Exhausted budgets return `429` until the window resets. On OpenShift AI 3.5.1 and earlier, add `"stream":true` to every request body in this chapter: non-streaming responses through the gateway arrive empty there ([known issue](../KNOWN-ISSUES.md#non-streaming-requests-return-an-empty-body)).

List the policies MaaS created:

```bash
oc get tokenratelimitpolicy -A
```

Inspect the TinyLlama policy for `department-b`'s limited plan:

```bash
oc get tokenratelimitpolicy maas-trlp-tinyllama -n ai-models -o json \
  | jq -r '.spec.limits | to_entries[] | "\(.key): \(.value.rates[0].limit) tok / \(.value.rates[0].window)"'
```

Expected output — the 1,000 tok/min value from your `MaaSSubscription`. The limit key name can vary; match on the rate:

```
tokens-1000-per-1m: 1000 tok / 1m
```

> [!IMPORTANT]
> Do not edit these `TokenRateLimitPolicy` resources directly. The MaaS controller reconciles them from the subscription.

### Tighten the limit for the demo

Lower TinyLlama to **100 tokens per minute** so one request can exhaust the budget. TinyLlama is the second `modelRefs` entry (`/spec/modelRefs/1`):

```bash
oc patch maassubscription limited-plan -n models-as-a-service --type=json \
  -p='[{"op":"replace","path":"/spec/modelRefs/1/tokenRateLimits/0/limit","value":100}]'
```

Wait for the MaaS controller to write the new value into the generated policy and for Kuadrant to enforce it:

```bash
oc wait tokenratelimitpolicy/maas-trlp-tinyllama -n ai-models \
  --for=jsonpath='{.spec.limits.*.rates[0].limit}'=100 --timeout=120s
oc wait tokenratelimitpolicy/maas-trlp-tinyllama -n ai-models \
  --for=condition=Enforced --timeout=120s
```

Verify the underlying policy:

```bash
oc get tokenratelimitpolicy maas-trlp-tinyllama -n ai-models -o json \
  | jq -r '.spec.limits | to_entries[] | "\(.key): \(.value.rates[0].limit) tok / \(.value.rates[0].window)"'
```

Expected output:

```
tokens-100-per-1m: 100 tok / 1m
```

Allow at least 65 seconds without TinyLlama traffic before each independent rate-limit test so the previous one-minute budget expires. A routine quota update is reconciled by the controllers; a gateway restart is a troubleshooting step, not a quota reset.

### Smoke test with curl

Use the `limited-plan` key. A `department-a` key has no TinyLlama access. Observe Usage and run the `oc` checks in this same terminal.

Send one request to consume tokens, then a second that should be rejected:

```bash
curl -sS --max-time 60 -o /dev/null -w 'HTTP:%{http_code}\n' \
  -X POST https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Write a short paragraph about the history of bread."}],"max_tokens":200}'

curl -sS --max-time 60 -o /dev/null -w 'HTTP:%{http_code}\n' \
  -X POST https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Write a short paragraph about the history of bread."}],"max_tokens":200}'
```

Expected:

```
HTTP:200
HTTP:429
```

Treat that as a warm-up. The first `429` becomes the dashboard baseline; waiting alone does not show an increase. The burst below first waits 90 seconds so metrics are collected and the budget window resets.

Send 10 rapid requests and count status codes:

```bash
sleep 90
for i in $(seq 1 10); do
  curl -sS --max-time 60 -o /dev/null -w "%{http_code}\n" \
    -X POST https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
    -H "Authorization: Bearer $MAAS_API_KEY" \
    -H 'Content-Type: application/json' \
    -d '{"model":"tinyllama","messages":[{"role":"user","content":"test"}],"max_tokens":50}'
done | sort | uniq -c
```

Expected output — a mix of `200` and `429`:

```
   1 200
   9 429
```

Counts depend on generated tokens and remaining budget. Without the wait, all ten may return `429`. A short completion under 100 tokens can allow more than one `200`.

> [!NOTE]
> Limits count actual tokens from `usage.total_tokens`, not request count. Rejected requests never reach the model server.

### Troubleshooting

If every request returns `200` and you never see a `429`:

1. **Confirm the key is `limited-plan`.** Keys are bound to the subscription chosen at creation. Recreate the department-b key if you are using the department-a key.
2. **Confirm the generated policy is `100`:**

   ```bash
   oc get tokenratelimitpolicy maas-trlp-tinyllama -n ai-models -o json \
     | jq '.spec.limits[].rates[0].limit'
   ```

3. **Confirm telemetry is Enforced:**

   ```bash
   oc get telemetrypolicy maas-telemetry -n openshift-ingress
   oc get tokenratelimitpolicy maas-trlp-tinyllama -n ai-models \
     -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
   ```

4. **Confirm Limitador sees TinyLlama traffic:**

   ```bash
   oc port-forward -n kuadrant-system svc/limitador-limitador 8080:8080 &
   LIMITADOR_FORWARD_PID=$!
   sleep 2
   curl -s http://localhost:8080/metrics | grep tinyllama
   kill "$LIMITADOR_FORWARD_PID"
   ```

   Look for `limitador_namespace="ai-models/tinyllama-kserve-route"`. If only `granite-2b` appears, restart the gateway and retry.

5. **Check Authorino for `selected_subscription_key`.** Limits are skipped if that metadata is missing:

   ```bash
   oc logs -n kuadrant-system deploy/authorino --tail=50 | grep selected_subscription
   ```

   `no such key: selected_subscription` (without `_key`) and `no such key: identity` for the expression `auth.identity.selected_subscription` are benign: they come from metric labels on unauthenticated or denied requests. Investigate only errors that mention `selected_subscription_key` or `subscription-info`.

6. **If steps 1–5 pass and you still only see `200`s**, check gateway logs for `Task failed` and compare RHCL with [known issues](../KNOWN-ISSUES.md#rhcl-142-wasm-task-failure). That 1.4.2 platform bug was not seen on the 1.4.3 validation cluster.

## Step 3: Show consumption and rejections in OpenShift AI

Return to the Usage view opened in Step 1. Keep the `limited-plan` subscription selected and leave **Model → All** when checking gateway rejection counts: the platform's rate-limited counter does not carry the same model label as its token counter.

After the test:

1. Allow 1–2 minutes for collection, then click **Refresh**.
2. Show **Total rate limited**, then inspect your user/subscription usage in the token consumption table.
3. Compare **Total tokens** and the token consumption chart/table with the pre-test values. Successful requests consume tokens; rejected requests do not run inference and consume no model tokens.
4. Switch the Model filter to TinyLlama to inspect its token consumption, then reset it to **All** for the rejection comparison.

![OpenShift AI Usage dashboard filtered to limited-plan, showing token consumption and nine rate-limit rejections](../img/maas-usage-rate-limiting.png)

*Example after the 100-token/minute test: `limited-plan` has **9** rate-limit rejections. This six-hour view includes preparation traffic, so its **21** total requests are not just the ten-request burst. The quota was restored to 1,000 tokens/minute after the test.*

### HTTP 429 works but Total rate limited is zero

The dashboard counts **increases between collected counter samples**, rather than displaying the cumulative rejection counter. If the first rejection creates a series at `1` and every subsequent scrape still sees `1`, `increase()` is `0`. This can also hide an entire first burst if all its rejections occur before the first scrape. Waiting longer or widening the time range cannot recover the missing initial increase.

1. Select **User → All**, **Subscription → limited-plan**, **Model → All**, and **Last 30 minutes**.
2. After the first rejected request, allow 1–2 minutes for collection.
3. Repeat the ten-request burst from Step 2 and confirm it includes `429` responses.
4. Allow another 1–2 minutes, then click **Refresh**. The counter now has a baseline and a higher sample, so Usage can show the increase.

For example, collected values of `1 → 10` show approximately nine new rejections; the first rejection remains part of the baseline. Exact dashboard counts can differ because counter increases are sampled and extrapolated. Keep the baseline and repeat burst inside the selected reporting period.

**The acceptance criteria are both:** curl demonstrates `HTTP:429` once the token budget is exhausted, and the built-in Usage dashboard shows nonzero token consumption and rate-limit rejections. Chapter 5's three subscription/model combinations should remain visible when the filters are cleared.

### Optional: Check the metrics pipeline

For troubleshooting, query the AI monitoring stack used by Usage. This needs no extra dashboard, datasource, or OpenShift console plugin:

```bash
oc exec -n openshift-user-workload-monitoring sts/prometheus-user-workload -c prometheus -- \
  curl -s 'http://thanos-querier-data-science-thanos-querier.redhat-ods-monitoring.svc.cluster.local:10902/api/v1/query?query=authorized_hits_total' \
  | jq '.data.result[] | {user: .metric.user, subscription: .metric.subscription, model: .metric.model, tokens: .value[1]}'

oc exec -n openshift-user-workload-monitoring sts/prometheus-user-workload -c prometheus -- \
  curl -s 'http://thanos-querier-data-science-thanos-querier.redhat-ods-monitoring.svc.cluster.local:10902/api/v1/query?query=limited_calls_total' \
  | jq '.data.result[] | {user: .metric.user, subscription: .metric.subscription, route: .metric.limitador_namespace, rejections: .value[1]}'
```

These queries show current cumulative counters; Usage shows increases for its reporting period. The AI pipeline exposes `authorized_hits_total` and `limited_calls_total`; raw user-workload Prometheus uses `authorized_hits` and `limited_calls`. Chapter 5 explains that distinction and the shipped chart's fixed two-hour window.

To distinguish a baseline-only counter from a collection failure, compare the cumulative rejection count above with its increase:

```bash
oc exec -n openshift-user-workload-monitoring sts/prometheus-user-workload -c prometheus -- \
  curl -sG 'http://thanos-querier-data-science-thanos-querier.redhat-ods-monitoring.svc.cluster.local:10902/api/v1/query' \
  --data-urlencode 'query=sum(increase(limited_calls_total{user!="",subscription="limited-plan"}[30m])) or vector(0)' \
  | jq '.data.result'
```

A positive cumulative count with zero increase matches the baseline case described above. No cumulative series after collection calls for checking the `limitador-metrics` ServiceMonitor and AI collector from [Configure observability](../chapter-3/observability.md). If the increase is positive but Usage stays at zero, check the dashboard filters and confirm `authorized_hits_total` has matching `user`, `subscription`, and `limitador_namespace` labels for successful traffic in the same period: the shipped dashboard joins rejection counts to those token-usage series to apply its Model filter.

## Step 4: Restore the demo quota

Restore the quota even if the test fails or the session is interrupted. The budget change applies to every user of this subscription/model.

Return TinyLlama to the 1,000 tokens/minute demo limit after testing:

```bash
oc patch maassubscription limited-plan -n models-as-a-service --type=json \
  -p='[{"op":"replace","path":"/spec/modelRefs/1/tokenRateLimits/0/limit","value":1000}]'
```

Wait for the generated policy to show `1000`:

```bash
oc wait tokenratelimitpolicy/maas-trlp-tinyllama -n ai-models \
  --for=jsonpath='{.spec.limits.*.rates[0].limit}'=1000 --timeout=120s
```

The traffic command in Step 5 first waits for the one-minute budget window to reset.

## Step 5: Explore built-in model observability

Stay in **OpenShift AI → Observe & monitor → Dashboard**. These views use the metrics stack from [Configure observability](../chapter-3/observability.md):

| View | What to demonstrate |
|---|---|
| **Usage** | Token consumption by subscription/model, request counts, and rate-limit rejections |
| **Models** | Model deployments, token throughput, request success rate, latency, and time to first token |
| **LLM Traffic** | Request throughput, error rate, and token throughput for llm-d |
| **LLM Performance** | Latency, time to first token, inter-token latency, and KV cache metrics |
| **LLM Utilization** | GPU utilization, running requests, and waiting requests |

Generate a few successful requests on both models with the restored quota:

```bash
sleep 65
for i in $(seq 1 5); do
  for model in granite-2b tinyllama; do
    curl -sS --max-time 60 -o /dev/null -w "$model HTTP:%{http_code}\n" \
      -X POST https://$ROUTE_HOST/ai-models/$model/v1/chat/completions \
      -H "Authorization: Bearer $MAAS_API_KEY" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg model "$model" \
        '{model:$model,messages:[{role:"user",content:"Name one benefit of Kubernetes."}],max_tokens:30}')"
  done
done
```

Expect `HTTP:200` for every request. Choose the `ai-models` project/namespace and relevant model where those filters are available, allow a scrape interval, and refresh. Rate-limited requests stop at the gateway, so model performance panels describe the requests that actually reached vLLM. A brief demo burst can leave rate charts sparse; choose a time range covering the traffic. A GPU panel also needs the GPU metrics exporter to be collected; an empty GPU panel does not invalidate the token-consumption or rate-limit demo.

OpenShift AI 3.5 creates model PodMonitors automatically. If model metrics are absent, inspect the existing monitors and model pod labels before adding anything:

```bash
oc get podmonitor -n ai-models --show-labels
oc get pods -n ai-models --show-labels
oc get pods -n redhat-ods-monitoring
```

Do not add a second scrape of the same model to fix an empty chart; diagnose the existing monitor, collector, filters, and traffic first. For details, see [OpenShift AI observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-observability_managing-rhoai).

## Revoke the test API keys

Once all exercises and presentations are finished, revoke both keys using the [key cleanup](../chapter-3/api-keys.md#cleanup) and confirm **403**. Historical usage metrics remain available.
