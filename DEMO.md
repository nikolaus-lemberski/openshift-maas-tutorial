# MaaS demo runbook

Complete [Part 1](README.md#part-1-install-and-configure), including [creating both demonstration keys](chapter-3/api-keys.md), and a rehearsal of Chapters 4–6 before presenting. Operator installation and model image pulls take several minutes; prepare the cluster and showback traffic beforehand. This runbook assumes the same OpenShift AI 3.5 setup and resources as the tutorial.

## Prepare

Use Bash from the repository root. Retain the two API keys as `MAAS_API_KEY_A` (standard-plan) and `MAAS_API_KEY_B` (limited-plan). If a key is lost or revoked, recreate it in [Create demonstration API keys](chapter-3/api-keys.md). Keep the keys through the presentation; revoke them afterward.

```bash
: "${MAAS_API_KEY_A:?Export the department-a key}"
: "${MAAS_API_KEY_B:?Export the department-b key}"
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
./chapter-1/7-verify-maas.sh
oc wait llminferenceservice/granite-2b llminferenceservice/tinyllama \
  -n ai-models --for=condition=Ready --timeout=120s
oc wait maasmodelref/granite-2b maasmodelref/tinyllama \
  -n ai-models --for=condition=Ready --timeout=120s
oc wait maassubscription/standard-plan maassubscription/limited-plan \
  maasauthpolicy/standard-access maasauthpolicy/limited-access \
  -n models-as-a-service --for=condition=Ready --timeout=120s
oc wait dscinitialization/default-dsci --for=condition=MonitoringStackAvailable --timeout=120s
oc wait dscinitialization/default-dsci --for=condition=PersesAvailable --timeout=120s
oc wait persesdashboard/dashboard-3-maas-usage-admin -n redhat-ods-monitoring \
  --for=condition=Available --timeout=120s
oc wait tokenratelimitpolicy/maas-trlp-tinyllama -n ai-models \
  --for=jsonpath='{.spec.limits.*.rates[0].limit}'=1000 --timeout=10s
```

All checks must pass. If TinyLlama is still at 100 tokens/minute, use [Chapter 6's quota restoration](chapter-6/README.md#step-4-restore-the-demo-quota), then allow at least 65 seconds without TinyLlama traffic. Verify [observability setup](chapter-3/observability.md), including `captureUser: true`, run [Chapter 5's comparable usage traffic](chapter-5/README.md#step-1-generate-comparable-usage), and allow another 1–2 minutes for metrics. Confirm nonzero values before starting the presentation.

Find the OpenShift AI dashboard address (`https://rh-ai.apps.<cluster-domain>`):

```bash
oc get ingresses.config.openshift.io cluster -o jsonpath='https://rh-ai.{.spec.domain}{"\n"}'
```

Open OpenShift AI as an administrator at **Settings → MaaS governance**, and keep **Observe & monitor → Dashboard → Usage** ready in another tab. This demo uses the built-in OpenShift AI dashboards; it needs no additional dashboard in the OpenShift console.

## Present

1. **Governance:** Show `standard-plan` and `limited-plan`, their department owners, token limits, and corresponding authorization policies. Explain that subscription names map departments to usage; the dashboard does not filter directly by OpenShift group name.
2. **Selective access:** Run Chapter 4, first with the department-a key and then with the department-b key. Department-a sees Granite; department-b sees both models. Run the direct TinyLlama request with the department-a key (`403`), then department-b's requests (`200`). Each key is bound to the subscription chosen at creation, so both departments can be demonstrated from this terminal.
3. **Showback:** In Usage, select a time period covering the prepared traffic. Compare standard-plan/Granite against limited-plan/Granite and TinyLlama. Clear both Model and Subscription filters for an overall comparison, then switch **View by** between subscription and model. Show the token consumption table. One admin owns both keys, so one active user is expected.
4. **Export:** Hover over the Token consumption chart and choose **Export time series data as CSV**. Open the downloaded CSV and show the timestamp and subscription/model series headers. This is sampled usage attribution; the shipped chart uses a fixed two-hour increase window in 3.5. Use the Usage overview/table for the selected-period totals.
5. **Enforcement:** Note the current Usage totals, then follow Chapter 6 to lower TinyLlama to 100 tokens/minute, wait for the generated policy, and run the rate-limit smoke test. Expect a successful request followed by `429` responses once actual token consumption exhausts the budget. Allow a fresh budget window between independent tests; a new key for the same user does not reset it. Refresh **Usage** after collection, select `limited-plan` with **Model → All**, and show nonzero **Total rate limited**. If a new rejection series only establishes a baseline, allow a scrape interval and repeat the burst.
6. **Operations:** Restore the quota (Chapter 6, Step 4), send successful traffic (Step 5), and explore **Models**, **LLM Traffic**, **LLM Performance**, and **LLM Utilization** in OpenShift AI. Use `ai-models` and the relevant model filters where available. Token consumption in **Usage** and actual `429` enforcement are required demo outcomes; these performance views add context.

## Finish or repeat

Restore TinyLlama to 1,000 tokens/minute using [Chapter 6, Step 4](chapter-6/README.md#step-4-restore-the-demo-quota) if you have not already, and wait for the budget window to expire. Keep the keys if another presentation is planned; otherwise revoke the tutorial test keys in **Gen AI Studio → API Keys**. If PostgreSQL's demo pod was replaced, its nonpersistent database may have lost the key records; recreate keys before the next run.

Use the [key cleanup](chapter-3/api-keys.md#cleanup) to verify both revocations. The two models and operators remain running so the demo can be repeated. The [known issues](KNOWN-ISSUES.md) cover the streaming workaround for OpenShift AI 3.5.1 and earlier and the missing Usage-tab startup race.
