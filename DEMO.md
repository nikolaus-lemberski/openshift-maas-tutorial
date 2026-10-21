# MaaS demo runbook

Complete Chapters 1–6 before presenting. Operator installation and model image pulls take several minutes; prepare the cluster and showback traffic beforehand. This runbook assumes the same OpenShift AI 3.5 setup and resources as the tutorial.

## Prepare

Use Bash from the repository root. Retain the two API keys created in Chapter 4 as `MAAS_API_KEY_A` (standard-plan) and `MAAS_API_KEY_B` (limited-plan). If a key is lost or revoked, follow Chapter 4's group-switch and key-creation steps to replace it. Keep the keys through the presentation; revoke them afterward.

```bash
: "${MAAS_API_KEY_A:?Export the department-a key from Chapter 4}"
: "${MAAS_API_KEY_B:?Export the department-b key from Chapter 4}"
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

All checks must pass. If TinyLlama is still at 100 tokens/minute, use [Chapter 6's quota restoration](chapter-6/README.md#restore-the-demo-quota), then allow at least 65 seconds without TinyLlama traffic. Verify Chapter 5's `captureUser: true` setting, run its [comparable usage traffic](chapter-5/README.md#step-3-generate-comparable-usage), and allow another 1–2 minutes for metrics. Confirm nonzero values before starting the presentation.

Find the OpenShift AI dashboard address:

```bash
oc get gatewayconfig default-gateway -o jsonpath='https://{.status.domain}{"\n"}'
```

Open OpenShift AI as an administrator at **Settings → MaaS governance**, and keep **Observe & monitor → Dashboard → Usage** ready in another tab. This demo uses the built-in OpenShift AI dashboards; it needs no additional dashboard in the OpenShift console.

## Present

1. **Governance:** Show `standard-plan` and `limited-plan`, their department owners, token limits, and corresponding authorization policies. Explain that subscription names map departments to usage; the dashboard does not filter directly by OpenShift group name.
2. **Selective access:** Run Chapter 4's model-list checks with each key. Department-a sees Granite; department-b sees both models. Run the direct TinyLlama request with the department-a key (`403`), then department-b's requests (`200`). Keys retain the group snapshot from creation, so both can be demonstrated from the same terminal after switching the admin to department-b.
3. **Showback:** In Usage, select a time period covering the prepared traffic. Compare standard-plan/Granite against limited-plan/Granite and TinyLlama. Clear both Model and Subscription filters for an overall comparison, then switch **View by** between subscription and model. Show the token consumption table. One admin owns both keys, so one active user is expected.
4. **Export:** Hover over the Token consumption chart and choose **Export time series data as CSV**. Open the downloaded CSV and show the timestamp and subscription/model series headers. This is sampled usage attribution; the shipped chart uses a fixed two-hour increase window in 3.5.1. Use the Usage overview/table for the selected-period totals.
5. **Enforcement:** Note the current Usage totals, then follow Chapter 6 to lower TinyLlama to 100 tokens/minute, wait for the generated policy, and run the rate-limit smoke test. Expect a successful request followed by `429` responses once actual token consumption exhausts the budget. Allow a fresh budget window between independent tests; a new key for the same user does not reset it. Refresh **Usage** after collection, select `limited-plan` with **Model → All**, and show nonzero **Total rate limited**. If a new rejection series only establishes a baseline, allow a scrape interval and repeat the burst.
6. **Operations:** Restore the quota, send successful traffic, and explore **Models**, **LLM Traffic**, **LLM Performance**, and **LLM Utilization** in OpenShift AI. Use `ai-models` and the relevant model filters where available. Token consumption in **Usage** and actual `429` enforcement are required demo outcomes; these performance views add context.

## Finish or repeat

Restore TinyLlama to 1,000 tokens/minute using Chapter 6 and wait for the budget window to expire. Keep the keys if another presentation is planned; otherwise revoke the tutorial test keys in **Gen AI studio → API keys**. If PostgreSQL's demo pod was replaced, its nonpersistent database may have lost the key records; recreate keys before the next run.

The two models and operators remain running so the demo can be repeated. The [known issues](KNOWN-ISSUES.md) cover the non-streaming response workaround and the missing Usage-tab startup race.
