# Known Platform Issues

**Current validation (2026-10-23):** OpenShift 4.20.42, OpenShift AI/rhods-operator 3.5.2, RHCL 1.4.3, COO 1.5.3, Red Hat OpenTelemetry 0.158.0. Granite 2B and TinyLlama use `LLMInferenceService` + `InferencePool`/EPP on NVIDIA L4 GPUs. Fresh Demo Platform cluster; Chapter 1 installer with `--scale-down-demo-model`; administrator demonstration keys for Part 2.

**Previous validation:** OpenShift 4.20.41 / OpenShift AI 3.5.1 (2026-10-20); OpenShift 4.20.32 / OpenShift AI 3.4.3 / RHCL 1.4.2.

## Validation scope

The 3.5.2 fresh-cluster replay covered the Chapter 1 installer, early model start, groups/governance, both models Ready, observability stack, demonstration keys with one-day `expiresAt`, selective access (`department-a` TinyLlama `403`; department-b both models `200`), Thanos `authorized_hits_total` for all three subscription/model series, token rate limiting (smoke `200` then `429`; burst `2×200` / `8×429`), quota restored to 1,000, and CLI key revocation (`403`). Browser Usage/CSV export was not exercised in this run; the non-streaming retest is described [below](#non-streaming-requests-return-an-empty-body).

Starting point: installed OpenShift AI 3.5 with GPUs, gateway, registry access, and default storage. Single-GPU time-slicing was tested on 3.4, not 3.5. Automatic operator channels can install newer builds. The demo PostgreSQL loses key records if its pod is replaced. Shared vs independent per-user budgets were not verified: this replay used one administrator identity for both keys.

The Chapter 1 installer has mocked CLI tests (`python3 -m unittest discover -s chapter-1/tests -v`). The full installer completed on 4.20.42 / 3.5.2. The installer covers Chapter 1 only.

## Kuadrant dependency discovery on a fresh installation

During a fresh RHCL 1.4.3 installation on 2026-10-20, the Kuadrant Operator started in the same second that the Limitador CRD was created. Its startup log reported `limitador operator is not installed, skipping related watches and reconcilers`. Kuadrant stayed `Ready=False` with reason `MissingDependency` after the Limitador Operator and its CRD became healthy, and no Limitador instance was created. Waiting for the RHCL CSV to reach `Succeeded` did not resolve the startup state.

Replacing the Kuadrant Operator pod after the dependency was available enabled the missing reconcilers, created the Limitador instance, and changed Kuadrant to `Ready=True`. A deployment `rollout restart` was ineffective in this run: OLM reverted the restart annotation and removed the new ReplicaSet's pod while retaining the original pod. [Chapter 1](chapter-1/README.md#kuadrant) now checks dependency readiness and refreshes stale operator discovery before applying the Kuadrant manifest.

## OpenShift AI 3.5 configuration changes

- Enable MaaS with `spec.components.aigateway.modelsAsAService`, alongside `aigateway.managementState: Managed`. The deprecated KServe field blocks new enablement.
- Configure tenant telemetry on `MaasTenantConfig/default-tenant`, not the deprecated `Tenant` resource. The default MaaS API now runs in `redhat-ai-gateway-infra`.
- Do not add `maasAuthPolicies` to `OdhDashboardConfig`: fresh 3.5 installations reject it. Use **Settings → MaaS governance** for subscription and authorization management.
- Gateway discovery prefers the first ready HTTPS listener. Set the external Route hostname on `http` and `https`, and retain a second unrestricted HTTPS listener, `https-router`, after `https` for the OpenShift Router's backend TLS connection. Setting the hostname only on HTTP was reproduced on the fresh 3.5.1 cluster: `/v1/tenants` returned `500` and the API Keys page reported `maas-api is not available`, despite healthy deployments and an externally reachable API. Adding the HTTPS hostname and fallback resolved discovery (`200`) and the dashboard API key search (`200`). Restricting every HTTPS listener causes router `503` responses and `filter_chain_not_found`. The former `MAAS_API_URL` patch on `rhods-dashboard` is unnecessary.
- MaaS model discovery returns canonical IDs such as `publishers/ai-models/models/granite-2b`; the short inference model names still work.
- The gateway default AuthPolicy is `maas-gateway-auth` (it was `gateway-default-auth` on 3.5.1).
- Generated `TokenRateLimitPolicy` limit keys are `tokens-<limit>-per-<window>` (for example `tokens-1000-per-1m`). Earlier 3.5.1 keys used the `models-as-a-service-<plan>-<model>-tokens` form. Match on the rate, not the key name.
- Revoked or invalid `sk-oai-` keys return HTTP `403` from `/maas-api/v1/models`. A missing `Authorization` header still returns `401`.

## Embedded Usage dashboard prerequisites and startup race

The 3.5 Usage dashboard requires the AI monitoring stack (COO and OpenTelemetry), user labels (`captureUser: true`), and a healthy `PersesDashboard/dashboard-3-maas-usage-admin`. The tutorial uses only built-in OpenShift AI dashboards; it does not require the additional OpenShift console UIPlugin, custom dashboard, datasource, or its RBAC. The AI-managed `data-science-perses` backend in `redhat-ods-monitoring` remains required. Token-budget enforcement stays in the MaaS gateway and Kuadrant/Limitador; the AI stack displays its metrics.

The AI monitoring pipeline exposes `authorized_hits_total` and `limited_calls_total`; user workload Prometheus exposes the raw `authorized_hits` and `limited_calls` metrics. MaaS creates a labeled `limitador-metrics` ServiceMonitor in `redhat-ods-monitoring` for the AI collector. Avoid duplicate scrapes. Token consumption has a model label, while the rejection counter does not carry that same model label; keep **Model → All** when demonstrating Usage rejection counts. For a newly created rejection series, allow a baseline scrape and another burst before expecting `increase()` to show nonzero rejections.

`MonitoringStackAvailable` and `PersesAvailable` can become True on `default-dsci` before the Prometheus and Perses PVCs bind. Wait for those PVCs and the Prometheus/Perses pods; do not treat the DSCI conditions alone as a ready stack.

If MaaS creates its dashboard before the Perses backend starts, the dashboard can retain a `PersesBackendError` condition and the Usage tab is absent. After waiting for the backend, adding/updating an annotation on the dashboard successfully retriggered reconciliation on the validation cluster. [Chapter 3, Step 5](chapter-3/README.md#step-5-enable-the-labels-required-by-usage) includes the checks and workaround.

The shipped dashboard excludes series with an empty user label. Enabling user capture affects new traffic only. `increase()` also needs multiple samples: a first successful request can establish a baseline while the displayed total remains zero.

The shipped token chart uses a fixed two-hour increase window. Its CSV export is a time-series export (timestamp plus series columns), not an invoice or a direct export of the user table. Select **View by → By subscription** for subscription-labeled series.

## Token rate limiting verified on 3.5.2

With TinyLlama temporarily limited to 100 tokens/minute, the smoke test returned **200 then 429**. A ten-request streaming burst returned **2×200 and 8×429** on RHCL 1.4.3 (counts vary with generated tokens and remaining budget). The quota was restored to 1,000 tokens/minute afterward. Cumulative `limited_calls_total` for `limited-plan` / TinyLlama was **9**.

## RHCL 1.4.2 Wasm task failure

On RHCL 1.4.2, the gateway Wasm filter could fail its Limitador callout on every `/v1/chat/completions` request (`kuadrant_wasm_shim: Task failed: Some("N")`). Token usage was never recorded, so a 100 tok/min budget never produced `429`. Restarting Limitador and the gateway did not clear it. This affected both Granite and TinyLlama on a fresh `maas-default-gateway` pod.

The 3.5.1 and 3.5.2 validations on RHCL **1.4.3** did not hit this. If an older RHCL build still only returns `200`:

```bash
GW_POD=$(oc get pods -n openshift-ingress -l 'gateway.networking.k8s.io/gateway-name=maas-default-gateway' -o jsonpath='{.items[0].metadata.name}')
oc logs $GW_POD -n openshift-ingress --since=2m | grep "Task failed"
oc get subscription rhcl-operator -n kuadrant-system -o jsonpath='{.status.installedCSV}{"\n"}'
```

A Usage dashboard is not proof of enforcement; confirm actual `429` responses.

## Rate limiting needs vLLM's `--enable-force-include-usage`

The tutorial retains this flag on both models. In the earlier 3.4.3 validation, without it MaaS token rate limiting silently failed: the Kuadrant Wasm shim reads `usage.total_tokens` from the response to track consumption, but plain streaming responses don't include a `usage` object unless the client opts in with `stream_options.include_usage` — something you can't rely on callers to do. Confirmed on 3.4.3: 10 requests against a 100 tok/min budget all returned `200`, never a `429`, with gateway logs showing `Missing json property: /usage/total_tokens`.

The [early model-start step](chapter-1/README.md#start-the-model-downloads) deploys both models with `--enable-force-include-usage` from the start, which makes vLLM always emit `usage` regardless of client request shape. Verified fix: same 10-request burst now returns `1×200` then `9×429`.

## Non-streaming requests return an empty body

**Retested 2026-10-23 on OpenShift AI 3.5.2:** not reproduced. On a fresh installation with OpenShift AI **3.5.2**, Connectivity Link **1.4.3**, and Authorino Operator **1.4.4**, six non-streaming gateway requests (both keys, both models, including the first call) returned complete JSON bodies (671–713 bytes); the department-a TinyLlama request returned the expected `403`, and TinyLlama rate limiting with non-streaming requests behaved the same as streaming (smoke `200` then `429`; burst `2×200` / `8×429`). The tutorial therefore uses non-streaming requests. On 3.5.1 and earlier, add `"stream": true` to the chat requests; Chapter 4 shows the streamed variant of the Granite call.

**Retested 2026-10-20:** the issue still occurs on the current cluster with OpenShift AI **3.5.1**, Connectivity Link **1.4.3**, and Authorino Operator **1.4.4**. Granite requests used the same prompt and a 50-token output limit:

| Request path | Streaming | HTTP status | Response size |
|---|---|---|---|
| External MaaS gateway, first call | No | 200 | 0 bytes |
| External MaaS gateway | Yes | 200 | 3,765 bytes |
| External MaaS gateway, repeat | No | 200 | 0 bytes |
| Direct model service over HTTPS | No | 200 | 651 bytes |

The direct model returned a valid JSON completion. This isolates the failure to the gateway path, which includes the per-model EPP `ext_proc` and Kuadrant Wasm filters; this retest does not establish which filter is responsible. Use `"stream": true` on affected releases. Chapter 4's streamed `sed`/`jq` pipeline was checked against the live streamed response and displayed only `Hello! How can I assist you today?`. The temporary test API key was revoked after testing.

**Update search (2026-10-20):** [Connectivity Link 1.4.4](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/release_notes/rhcl-release-notes) was released on October 15 and requires the `stable-1.4` update channel. Its notes describe a fix for Wasm tasks stalling after certain CEL errors, but do not confirm a fix for this non-streaming empty-body symptom. The [upstream Wasm releases](https://github.com/Kuadrant/wasm-shim/releases) also include newer task-handling fixes. Neither those notes nor the search established that this exact issue is resolved. Connectivity Link 1.4.4 was not installed or tested in this investigation; an upgrade requires another non-streaming comparison before removing the workaround.
