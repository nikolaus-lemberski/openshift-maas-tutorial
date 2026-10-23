# Part 1 — Chapter 1: Install the base infrastructure

**Role:** cluster administrator. Start here. If models, governance, observability, and both demonstration keys already exist, continue at [Chapter 4](../chapter-4/README.md).

## Install for a demo

The installer configures this chapter's operators, gateway, Authorino TLS, database, monitoring, MaaS API, telemetry, and dashboard flags, then verifies. It does not install groups, governance, or the AI metrics stack, and it does not install OpenShift AI or GPU drivers. Add `--with-models` to submit Granite and TinyLlama so image pulls overlap with Chapter 2.

Start from a cluster that passes the prerequisite check, logged in with `oc` as cluster-admin. Choose flags **before** the first run. From the repository root:

```bash
./chapter-1/check-prereqs.sh
```

| Flag | Use when |
|---|---|
| `--scale-down-demo-model` | Demo Platform's default Llama occupies a GPU. |
| `--gpu-time-slicing` | One physical L4; advertise two shared slots. See [GPU time-slicing](#gpu-time-slicing-single-physical-gpu-only). |
| `--with-models` | Submit both model services after verification. Skip [Start the model downloads](#start-the-model-downloads) afterward. |

Then **one** install command. Demo Platform needs `--scale-down-demo-model`; a single L4 also needs `--gpu-time-slicing`.

Demo Platform (typical for this tutorial):

```bash
./chapter-1/install.sh --scale-down-demo-model --with-models
```

Two free GPUs, no Demo Platform Llama:

```bash
./chapter-1/install.sh --with-models
```

Demo Platform, one physical L4:

```bash
./chapter-1/install.sh --scale-down-demo-model --gpu-time-slicing --with-models
```

The installer reuses an existing RHCL subscription, preserves monitoring settings, and stops on error. The database uses disposable storage and example credentials. From the repository root, `./cleanup.sh` removes the tutorial resources and leaves those platform components installed.

Success with `--with-models` prints **Chapter 1 complete. Both model services submitted; continue with Chapter 2.** Without that flag it prints **Chapter 1 complete. Continue with starting the model downloads in chapter-1/README.md.** No variables need to carry over.

Where to go next:

| You ran | Continue with |
|---|---|
| The installer with `--with-models` | [Chapter 2](../chapter-2/README.md) |
| The installer without `--with-models` | [Start the model downloads](#start-the-model-downloads) (skip the manual steps) |
| No installer (manual setup) | [Enabling MaaS](#enabling-maas) below |

> [!TIP]
> For Red Hatters: install from [Demo Platform](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.openshift-ai-v3.prod&utm_source=webapp&utm_medium=share-link)
>
> Demo Platform ships a Llama model in `my-first-model` that occupies the GPU. Use `--scale-down-demo-model` on the installer, or scale it down before starting the model downloads: `oc scale deployment llama-32-3b-instruct-predictor -n my-first-model --replicas=0`
>
> Skip that command if the deployment does not exist.

## Version compatibility

This tutorial targets OpenShift AI **3.5.x**. Do not mix [3.4 MaaS commands](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas) with this setup:

| Setting | OpenShift AI 3.4 | This tutorial: 3.5 |
|---|---|---|
| MaaS enablement | `kserve.modelsAsService` | `aigateway.modelsAsAService` |
| Tenant configuration | `Tenant` | `AITenant` and `MaasTenantConfig` |
| Default MaaS API namespace | `redhat-ods-applications` | `redhat-ai-gateway-infra` |
| RHCL prerequisite | 1.3.x | 1.4.x; tested with 1.4.3 |

Use the [3.5 MaaS guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service) alongside this walkthrough.

## Enabling MaaS

MaaS exposes LLMs through managed endpoints with subscriptions, token quotas, and API keys. The steps below add the policy engine, gateway, database, and feature flags. Skip this section if the installer already succeeded.

Run all commands from the repository root in a Bash session. If your terminal runs zsh (the macOS default), type `bash` first. Check prerequisites:

```bash
./chapter-1/check-prereqs.sh
```

This walkthrough uses `default-dsc`, `default-dsci`, and `default-gateway`. For a different layout, complete the [llm-d platform setup](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/deploying-models-using-distributed-inference_distributed-inference) first.

### Red Hat Connectivity Link Operator

[Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/) (Kuadrant) supplies Gateway API auth and rate-limit policies.

Check for an existing installation:

```bash
oc get subscription -A | grep rhcl-operator
```

If present, reuse it and substitute its namespace in the waits below. Otherwise install it in `kuadrant-system`:

```bash
oc apply -f chapter-1/0-connectivity-link.yml
```

Wait for the operator:

```bash
oc wait subscription/rhcl-operator -n kuadrant-system \
  --for=jsonpath='{.status.installedCSV}' --timeout=600s
RHCL_CSV=$(oc get subscription rhcl-operator -n kuadrant-system -o jsonpath='{.status.installedCSV}')
oc wait csv "$RHCL_CSV" -n kuadrant-system \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

On timeout, inspect the Subscription conditions and InstallPlan.

### Kuadrant

Ensure the instance namespace exists, even if RHCL is installed elsewhere:

```bash
oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -
```

On a fresh install the Kuadrant Operator can start before Limitador/Authorino APIs exist and skip their reconcilers. The pre-check replaces that pod only when its logs show the skip (OLM can revert `oc rollout restart`). See [known issues](../KNOWN-ISSUES.md#kuadrant-dependency-discovery-on-a-fresh-installation).

```bash
./chapter-1/preflight-kuadrant.sh && oc apply -f chapter-1/1-kuadrant.yml
```

This deploys [Authorino](https://github.com/Kuadrant/authorino) and [Limitador](https://github.com/Kuadrant/limitador). Wait for Ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=600s
```

### Model serving prerequisites

Enable KServe if it is not already managed, then confirm llm-d dependencies:

```bash
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"kserve":{"managementState":"Managed"}}}}'
oc wait datasciencecluster/default-dsc --for=condition=KserveReady --timeout=600s
oc wait datasciencecluster/default-dsc \
  --for=condition=KserveLLMInferenceServiceDependencies --timeout=600s
oc get crd llminferenceservices.serving.kserve.io inferencepools.inference.networking.k8s.io
```

On timeout, inspect `oc get datasciencecluster default-dsc -o yaml`. This tutorial does not need LeaderWorkerSet or multi-node inference.

### Gateway

The Gateway is the single entry point for inference. MaaS auth and rate limits attach here.

#### TLS certificate

Apply a ConfigMap that uses a ClusterIP service, provisions a TLS certificate from the service-ca operator, and raises Envoy memory to 2Gi (the default 1Gi OOMs once Kuadrant Wasm filters load):

```bash
oc apply -f chapter-1/2-gw-service-tls-cm.yml
```

#### Get the Gateway class

```bash
export GW_CLASS=$(oc get gatewayclass -o custom-columns=NAME:.metadata.name,CTRL:.spec.controllerName --no-headers | grep "openshift.io/gateway-controller" | awk '{print $1}' | head -n 1)
: "${GW_CLASS:?No OpenShift GatewayClass found; complete the platform gateway setup first}"
oc wait gatewayclass/$GW_CLASS --for=condition=Accepted --timeout=300s
```

#### Create the external Route

Create the Route before the Gateway so `$ROUTE_HOST` is known at apply time. The backend Service appears when the Gateway is created.

```bash
envsubst '$GW_CLASS' < chapter-1/4-route.yml | oc apply -f -
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
: "${ROUTE_HOST:?The inference Route has no hostname}"
```

#### Deploy the Gateway

The `http` and `https` listeners advertise `$ROUTE_HOST`. Keep `https-router` after `https` with no hostname restriction so the OpenShift Router's backend TLS connection matches. Set the hostname on `https` at creation time: two HTTPS listeners on port 443 without hostnames fail Gateway API validation. Details: [known issues](../KNOWN-ISSUES.md#openshift-ai-35-configuration-changes).

```bash
envsubst '$GW_CLASS $ROUTE_HOST' < chapter-1/3-gateway.yml | oc apply -f -
```

### Configure Authorino

Authorino validates API keys against the MaaS API, so it must trust the cluster service CA.

```bash
oc -n kuadrant-system set env deployment/authorino \
SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

Issue a serving certificate for Authorino's authorization endpoint:

```bash
oc annotate service authorino-authorino-authorization -n kuadrant-system \
service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
```

Enable the TLS listener:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge --patch '
{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'
```

### MaaS API database

PostgreSQL stores API-key hashes, subscription bindings, expiration, and revocation. Subscriptions and auth policies are Kubernetes CRs; usage comes from the monitoring stack.

```bash
oc apply -f chapter-1/5-maas-db.yml
oc rollout status deployment/maas-postgres -n redhat-ods-applications --timeout=300s
```

This demo uses container-local storage, example credentials, and `sslmode=disable`. Replacing the pod loses key records. For a long-lived environment use persistent storage, managed credentials, and `sslmode=require` (or `verify-full`) against a TLS-enabled PostgreSQL server. Changing `sslmode` alone does not enable TLS on this demo database.

### User workload monitoring

Enable this **before** MaaS. On a fresh cluster:

```bash
oc apply -f chapter-1/6-user-workload-monitoring.yml
oc wait --for=create statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring --timeout=300s
oc rollout status statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring --timeout=300s
```

If `cluster-monitoring-config` already exists, merge `enableUserWorkload: true` into its `config.yaml` instead of replacing it.

### MaaS API layer

In 3.5, `kserve.modelsAsService` is deprecated. Enable MaaS on the AI Gateway:

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": {
          "managementState": "Managed"
        }
      }
    }
  }
}'
oc wait datasciencecluster/default-dsc --for=condition=ModelsAsAServiceReady --timeout=600s
```

The operator creates `AITenant` in `ai-tenants`, `MaasTenantConfig` in `models-as-a-service`, and the MaaS API in `redhat-ai-gateway-infra`. It copies the database secret and qualifies the PostgreSQL hostname. OGX is not required.

```bash
oc wait --for=create maastenantconfig/default-tenant -n models-as-a-service --timeout=300s
oc wait --for=condition=Ready maastenantconfig/default-tenant \
  -n models-as-a-service --timeout=300s
oc rollout status deployment/maas-api -n redhat-ai-gateway-infra --timeout=300s
```

### MaaS telemetry

Enable Kuadrant observability and tenant telemetry before models or subscriptions, so gateway Wasm filters are wired from the first request. This patch does not set `captureUser`; [Configure observability](../chapter-3/observability.md) enables it later, and rerunning this patch does not disable it.

```bash
oc patch kuadrant kuadrant -n kuadrant-system \
  --type merge \
  -p '{"spec":{"observability":{"enable":true}}}'
```

```bash
oc patch maastenantconfig default-tenant -n models-as-a-service \
  --type merge \
  -p '{
    "spec": {
      "telemetry": {
        "enabled": true,
        "metrics": {
          "captureOrganization": true,
          "captureModelUsage": true
        }
      }
    }
  }'
```

Restart the gateway so it picks up the filters:

```bash
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=300s
oc wait telemetrypolicy/maas-telemetry -n openshift-ingress --for=condition=Enforced --timeout=300s
oc rollout restart deployment -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
oc rollout status deployment -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --timeout=300s
```

Verify:

```bash
oc get podmonitor kuadrant-limitador-monitor -n kuadrant-system
oc get telemetrypolicy maas-telemetry -n openshift-ingress
```

### Enable Gen AI Studio

Enable Gen AI Studio, MaaS, and the embedded observability dashboard. `maasAuthPolicies` is rejected on a fresh 3.5 install; manage subscriptions in the MaaS UI.

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {
    "dashboardConfig": {
      "modelAsService": true,
      "genAiStudio": true,
      "observabilityDashboard": true
    }
  }
}'
```

### Gateway hostname discovery

3.5 discovers the MaaS API through `/v1/tenants`, which prefers the first ready HTTPS listener. Confirm both hostnames:

```bash
oc get gateway maas-default-gateway -n openshift-ingress \
  -o custom-columns=NAME:.spec.listeners[*].name,HOSTNAME:.spec.listeners[*].hostname
```

Keep `https-router` unrestricted. Restricting every HTTPS listener causes `503` / `filter_chain_not_found`. Hostname only on HTTP makes the API Keys page report `maas-api is not available`. The 3.4 `MAAS_API_URL` dashboard patch is not used.

### GPU time-slicing (single physical GPU only)

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

Skip this section if the cluster already has two free schedulable GPUs, or if the installer ran with `--gpu-time-slicing`. The 3.5.2 validation cluster has four L4s and does not need time-slicing.

For one physical L4, advertise two virtual GPUs:

```bash
oc apply -f chapter-1/gpu-time-slicing.yml
```

```bash
oc patch clusterpolicy gpu-cluster-policy --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"l4"}}}}'
```

```bash
oc rollout status daemonset/nvidia-device-plugin-daemonset -n nvidia-gpu-operator --timeout=120s
```

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

The GPU node should advertise `2`. Do not wait on the first node: it might be a control-plane node without a GPU.

### Verify

```bash
./chapter-1/7-verify-maas.sh
```

Every check must pass before starting the model downloads. The installer runs this script automatically.

## Start the model downloads

Skip this section if the installer already ran with `--with-models`.

Start Granite and TinyLlama now so image pulls overlap with group and governance setup. The services need the Gateway and GPUs from this chapter; they do not need department groups. MaaS registration and readiness checks follow in Chapter 3.

The command checks the Gateway's default deny policies, then submits the namespace, data connections, and model services. Keep those defaults: they [deny access](https://github.com/opendatahub-io/models-as-a-service/blob/main/maas-controller/README.md#subscription-model) until governance is configured.

```bash
set -o pipefail
oc wait authpolicy/maas-gateway-auth tokenratelimitpolicy/gateway-default-deny \
  -n openshift-ingress --for=condition=Enforced --timeout=300s && \
oc create namespace ai-models --dry-run=client -o yaml | oc apply -f - && \
oc apply -f chapter-1/granite-data-connection.yml \
  -f chapter-1/tinyllama-data-connection.yml && \
oc apply -f chapter-1/granite-inference-service.yml \
  -f chapter-1/tinyllama-inference-service.yml && \
oc get llminferenceservice granite-2b tinyllama -n ai-models
```

Stop on any error; the `&&` chain skips later applies if a check fails. Resolve the error and rerun this block.

Both services must be listed. They may not be `Ready` yet; do not wait here. Continue to [Chapter 2: Groups and governance](../chapter-2/README.md). If you inspect progress, `ImagePullBackOff` or repeated initialization failures need investigation now.

---

## Client TLS

The curl commands from [Create demonstration API keys](../chapter-3/api-keys.md) onward verify the gateway certificate by default. If the workstation already trusts the issuing CA, no extra curl options are needed. Otherwise export `CURL_CA_BUNDLE` to the CA file's absolute path.

For an isolated demo with an untrusted certificate, `curl -k` skips verification. Use it only as an explicit shortcut.

## Troubleshooting: API Keys page unavailable

If **API Keys** reports `maas-api is not available`:

```bash
oc logs deployment/maas-ui -n redhat-ods-applications --tail=10
```

If `/v1/tenants` returns `500` with `Unable to determine external hostname from Gateway status`, reapply the Gateway with both variables set. Keep `https-router` after `https`:

```bash
export GW_CLASS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.gatewayClassName}')
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
: "${GW_CLASS:?The Gateway has no class}"
: "${ROUTE_HOST:?The inference Route has no hostname}"
envsubst '$GW_CLASS $ROUTE_HOST' < chapter-1/3-gateway.yml | oc apply -f -
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=300s
./chapter-1/7-verify-maas.sh
```

The dashboard retries discovery every 30 seconds. After logs show `MaaS API URL discovered after retry`, refresh **Gen AI Studio → API Keys**.

## Troubleshooting: OpenShift AI dashboard unavailable

If the OpenShift AI dashboard stops loading while the OpenShift console still works, the gateway proxy was likely OOMKilled by Kuadrant Wasm filters.

```bash
oc get pods -n openshift-ingress -l 'gateway.networking.k8s.io/gateway-name'
```

```bash
oc get pods -n openshift-ingress -l 'gateway.networking.k8s.io/gateway-name' -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

`gw-options` already sets a 2Gi limit. Apply the same override to the operator-managed `data-science-gateway-config`:

```bash
oc patch configmap data-science-gateway-config -n openshift-ingress --type merge -p '{"data":{"deployment":"spec:\n  template:\n    spec:\n      containers:\n      - name: istio-proxy\n        resources:\n          limits:\n            cpu: \"2\"\n            memory: 2Gi\n          requests:\n            cpu: 100m\n            memory: 128Mi\n"}}'
```

```bash
oc rollout restart deployment -n openshift-ingress -l 'gateway.istio.io/managed'
```
