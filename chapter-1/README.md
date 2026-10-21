# Chapter 1: Infrastructure Setup

> **Complete this chapter first.** All subsequent chapters assume the infrastructure below is installed and working.

## Install for a demo

If your audience is focused on using MaaS, run the installer and continue with Chapter 2. It configures this chapter's operators, gateway, Authorino TLS, database, monitoring, MaaS API, telemetry, and dashboard, then runs the final verification. The manual walkthrough below explains each step for administrators.

Start with an installed OpenShift **4.20.x** / OpenShift AI **3.5.x** platform meeting the [prerequisites](#prerequisites), and log in with `oc` as a cluster admin. From the repository root:

```bash
./chapter-1/install.sh --check-only
./chapter-1/install.sh
```

`--check-only` checks local tools, admin access, platform versions/resources, the default StorageClass, gateway class, and free GPU capacity without changing the cluster. The installer adds dependency checks before creating Kuadrant and waits for components as it configures them. It preserves existing monitoring settings and reuses an existing RHCL subscription. It stops on an error; resolve the reported failure and rerun. Success ends with **Chapter 1 complete. Continue with chapter-2/README.md.** No shell variables need to be carried over from the installer.

For a Demo Platform cluster whose default Llama model occupies the GPU, use the explicit scale-down option. For the single-L4 alternative, also opt into time-slicing:

```bash
# Free the GPU used by the Demo Platform's default model:
./chapter-1/install.sh --scale-down-demo-model

# Alternative for one physical L4 GPU (see the time-slicing notes below):
./chapter-1/install.sh --scale-down-demo-model --gpu-time-slicing
```

Choose one installation command for your cluster. The installer checks Kubernetes GPU reservations; available GPU memory, registry connectivity for the later model images, and Chapter 5's storage capacity still need to meet the prerequisites. GPU slots already occupied by running models are counted as used. The database uses the disposable storage and example credentials described below. The script does not install OpenShift AI or the GPU drivers, or upgrade their versions.

## Prerequisites

- OpenShift **4.20.x** with OpenShift AI **3.5.x** installed, its dashboard available, and KServe/llm-d configured. This walkthrough starts after platform installation, using the default `default-dsc`, `default-dsci`, and `default-gateway` resources. For a different installation, complete the [llm-d platform setup](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/deploying-models-using-distributed-inference_distributed-inference) first.
- NVIDIA GPU Operator and drivers ready, with two free schedulable GPUs. The tested GPUs are L4 (24 GiB each). A single L4 with time-slicing is an alternative demo configuration, described below; that alternative was previously tested on 3.4, but has not been revalidated on 3.5.
- A working default StorageClass for the monitoring PVCs in Chapter 5 (at least 6 GiB total), plus capacity for the operators, gateway, monitoring, and two model pods
- Cluster image-pull access to `registry.redhat.io` and `quay.io`; the model weights are pulled as OCI images
- `curl` and `jq` available locally
- `oc` CLI logged in as a cluster admin
- `envsubst` available locally (typically provided by `gettext`)
- A local checkout of this repository, a Bash shell, and a browser for the dashboards

Run all commands from the repository root. Open Bash before starting, and keep that terminal for all chapters:

```bash
bash
```

Check local tools and platform resources:

```bash
command -v oc curl jq envsubst
oc whoami
oc get datasciencecluster default-dsc
oc get dscinitialization default-dsci
oc get gatewayconfig default-gateway
oc wait gatewayconfig/default-gateway --for=condition=Ready --timeout=300s
oc get storageclass
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

Confirm a StorageClass is marked `(default)`. GPU allocatable is capacity, not free capacity: check **Allocated resources** in `oc describe node <gpu-node>` and free resources used by other models before deploying. If the default platform resources or GPU capacity are missing, finish the prerequisite setup before continuing.

> [!TIP]
> For Red Hatters: install from [Demo Platform](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.openshift-ai-v3.prod&utm_source=webapp&utm_medium=share-link)
>
> If you installed from the Demo Platform, it ships a default Llama model in the `my-first-model` project that occupies the full GPU. Scale it down before Chapter 3 — otherwise Granite will fail to start with a GPU memory error: `oc scale deployment llama-32-3b-instruct-predictor -n my-first-model --replicas=0`
> 
> If that deployment does not exist on your cluster, skip this step.

## Check the OpenShift AI Version

The tutorial assumes OpenShift AI is already installed; it does not install or pin the AI operator. Check the installed release and update policy before continuing:

```bash
oc get clusterversion
oc get subscription rhods-operator -n redhat-ods-operator \
  -o custom-columns=CHANNEL:.spec.channel,APPROVAL:.spec.installPlanApproval,INSTALLED:.status.installedCSV
oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.release.version}{"\n"}'
```

The validation cluster uses OpenShift **4.20.41**, OpenShift AI **3.5.1**, and the `stable-3.x` channel with `Automatic` approval. Automatic approval follows the configured channel; it does not guarantee a specific minor version. If your cluster is older, follow the [supported upgrade procedure](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/) before continuing. Record the installed version when reproducing this tutorial.

## Enabling MaaS

Models-as-a-Service (MaaS) exposes LLMs through managed API endpoints with subscription-based governance — token quotas, rate limits, and API key authentication. Setting it up requires a policy engine, an API gateway, a database, and a few OpenShift AI feature flags. The sections below walk through each component.

### Red Hat Connectivity Link Operator

MaaS relies on the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) for routing and policy enforcement. [Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/) (built on the [Kuadrant](https://kuadrant.io/) project) supplies authentication, authorization, and rate-limiting policies that MaaS attaches to model endpoints.

Check for an existing RHCL installation first:

```bash
oc get subscription -A | grep rhcl-operator
```

If present, reuse it and substitute its installation namespace in the operator waits below. Otherwise install it in `kuadrant-system`:

```bash
oc apply -f chapter-1/0-connectivity-link.yml
```

This creates the `kuadrant-system` namespace, an OperatorGroup, and a Subscription that installs the operator from the Red Hat catalog.

Wait for the operator to be ready:

```bash
oc wait subscription/rhcl-operator -n kuadrant-system \
  --for=jsonpath='{.status.installedCSV}' --timeout=600s
RHCL_CSV=$(oc get subscription rhcl-operator -n kuadrant-system -o jsonpath='{.status.installedCSV}')
oc wait csv "$RHCL_CSV" -n kuadrant-system \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

These checks allow time for OLM to resolve and install the operator. On timeout, inspect the Subscription's conditions and InstallPlan before continuing.

### Kuadrant

Before creating the instance, check that the dependency APIs and operators are ready. On a fresh installation, the Kuadrant Operator can start before those APIs are available and skip their reconcilers. The pre-check below replaces its pod only if its startup logs show that this happened, so it discovers the now-installed dependencies before creating Kuadrant. Pod replacement is used because OLM can revert `oc rollout restart`.

The same pre-check is used by the demo installer. It stops on a failed check and applies the Kuadrant manifest only after the checks pass:

```bash
./chapter-1/preflight-kuadrant.sh && oc apply -f chapter-1/1-kuadrant.yml
```

This creates the Kuadrant instance, which deploys [Authorino](https://github.com/Kuadrant/authorino) (auth) and [Limitador](https://github.com/Kuadrant/limitador) (rate limiting) to enforce policies on Gateway API resources. Wait for it to become ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=600s
```

### Model Serving Prerequisites

Enable KServe if it is not already managed, then confirm llm-d dependencies are available:

```bash
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"kserve":{"managementState":"Managed"}}}}'
oc wait datasciencecluster/default-dsc --for=condition=KserveReady --timeout=600s
oc wait datasciencecluster/default-dsc \
  --for=condition=KserveLLMInferenceServiceDependencies --timeout=600s
oc get crd llminferenceservices.serving.kserve.io inferencepools.inference.networking.k8s.io
```

On timeout, inspect `oc get datasciencecluster default-dsc -o yaml` for dependency errors and complete the linked llm-d platform setup. The tutorial supplies its own MaaS gateway and configures RHCL authentication below; it does not require LeaderWorkerSet or multi-node inference.

### Gateway

The Gateway is the single entry point for all model inference traffic. Requests flow through it before reaching any model server, so every MaaS policy (auth, rate limits) is enforced in one place.

#### TLS certificate

Apply a ConfigMap that tells the Gateway controller to use a **ClusterIP** service (instead of a cloud LoadBalancer) and to auto-provision a TLS certificate via the OpenShift service-ca operator. We use ClusterIP because we will expose traffic through an OpenShift Route in the next step. The ConfigMap also raises the Envoy proxy memory limit to 2Gi — the default 1Gi is not enough once Kuadrant's Wasm policy filters are loaded.

```bash
oc apply -f chapter-1/2-gw-service-tls-cm.yml
```

#### Get the Gateway class

Look up the GatewayClass that is backed by the OpenShift gateway controller. This name varies by cluster, so we capture it dynamically.

```bash
export GW_CLASS=$(oc get gatewayclass -o custom-columns=NAME:.metadata.name,CTRL:.spec.controllerName --no-headers | grep "openshift.io/gateway-controller" | awk '{print $1}' | head -n 1)
: "${GW_CLASS:?No OpenShift GatewayClass found; complete the platform gateway setup first}"
oc wait gatewayclass/$GW_CLASS --for=condition=Accepted --timeout=300s
```

#### Create the external Route

In environments without **DNSPolicy** or MetalLB there is no external load balancer to assign an IP to the Gateway's ClusterIP service. An OpenShift Route bridges the gap by fronting the Gateway through the default OpenShift Router (HAProxy), giving it a publicly reachable hostname with re-encrypted TLS.

```bash
envsubst '$GW_CLASS' < chapter-1/4-route.yml | oc apply -f -
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
: "${ROUTE_HOST:?The inference Route has no hostname}"
```

Create the Route before the Gateway to obtain its assigned hostname. The backend Service will appear when the Gateway is created below.

#### Deploy the Gateway

Create the Gateway with HTTP (80) and HTTPS (443) listeners that accept routes from all namespaces. The `kuadrant.io/gateway: "true"` label tells Kuadrant to watch this Gateway for policy attachments, and the `security.opendatahub.io/authorino-tls-bootstrap: "true"` annotation triggers automatic EnvoyFilter creation so the Gateway trusts Authorino's TLS certificate.

The `http` and `https` listeners advertise `$ROUTE_HOST`. A second HTTPS listener, `https-router`, accepts the OpenShift Router's backend TLS connection without a hostname restriction. The hostname must be present on `https` at creation time: two HTTPS listeners on port 443 without hostnames fail Gateway API validation.

```bash
envsubst '$GW_CLASS $ROUTE_HOST' < chapter-1/3-gateway.yml | oc apply -f -
```

### Configure Authorino

Authorino is the authorization engine that validates API keys and enforces access policies on every inference request. It needs to make outbound HTTPS calls to the MaaS API (for API key validation and metadata lookups), so it must trust the cluster's internal CA certificates.

Set SSL environment variables for outbound communication:

```bash
oc -n kuadrant-system set env deployment/authorino \
SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

Generate a TLS certificate for Authorino's own authorization endpoint. The `serving-cert-secret-name` annotation tells the OpenShift service-ca operator to issue a signed certificate and store it in the named Secret:

```bash
oc annotate service authorino-authorino-authorization -n kuadrant-system \
service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
```

Patch the Authorino resource to enable the TLS listener, so the Gateway ↔ Authorino channel is encrypted:

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

### MaaS API Database

MaaS needs a PostgreSQL database to persist subscriptions, API keys, authorization policies, and usage-tracking data. This deploys a simple single-replica Postgres instance in the `redhat-ods-applications` namespace and creates a Secret (`maas-db-config`) with the connection string that the MaaS API reads at startup.

```bash
oc apply -f chapter-1/5-maas-db.yml
oc rollout status deployment/maas-postgres -n redhat-ods-applications --timeout=300s
```

This database uses container-local storage and example credentials for a disposable demo. Replacing its pod loses API-key records; recreate the keys if that happens. Use persistent storage and managed credentials for a long-lived environment.

### User Workload Monitoring

Enable user workload monitoring **before** enabling MaaS, which depends on it for a healthy installation. On this fresh cluster, apply the supplied configuration:

```bash
oc apply -f chapter-1/6-user-workload-monitoring.yml
oc wait --for=create statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring --timeout=300s
oc rollout status statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring --timeout=300s
```

On a cluster with an existing `cluster-monitoring-config`, merge `enableUserWorkload: true` into its `config.yaml` instead of replacing the other settings with this demo manifest.

### MaaS API Layer

Enable MaaS through the AI Gateway component. In OpenShift AI 3.5, `kserve.modelsAsService` is deprecated and cannot be changed from `Removed` to `Managed`. Use `aigateway.modelsAsAService` instead:

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

The operator creates the default `AITenant` in `ai-tenants`, a `MaasTenantConfig` in `models-as-a-service`, and the MaaS API in `redhat-ai-gateway-infra`. It copies the database secret into that infrastructure namespace and qualifies the PostgreSQL service hostname automatically. OGX (formerly Llama Stack) is not required for the MaaS API walkthrough.

Wait for the tenant configuration to exist, then wait for readiness:

```bash
oc wait --for=create maastenantconfig/default-tenant -n models-as-a-service --timeout=300s
oc wait --for=condition=Ready maastenantconfig/default-tenant \
  -n models-as-a-service --timeout=300s
oc rollout status deployment/maas-api -n redhat-ai-gateway-infra --timeout=300s
```

### MaaS Telemetry

Token rate limiting and chargeback metrics depend on Kuadrant observability and the MaaS `TelemetryPolicy`. Enable both now — before any models or subscriptions are deployed — so the gateway Wasm filters are wired correctly from the first inference request.

Wait for the MaaS tenant to become ready:

```bash
oc wait --for=condition=Ready maastenantconfig/default-tenant \
  -n models-as-a-service --timeout=300s
```

Enable Limitador metric scraping:

```bash
oc patch kuadrant kuadrant -n kuadrant-system \
  --type merge \
  -p '{"spec":{"observability":{"enable":true}}}'
```

Enable tenant telemetry (creates the `TelemetryPolicy` on the gateway):

```bash
oc patch maastenantconfig default-tenant -n models-as-a-service \
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

Restart the gateway so it picks up the new telemetry and rate-limit filters:

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

### Enable GenAI Studio

Enable Gen AI Studio, MaaS, and the embedded observability dashboard. The old `maasAuthPolicies` flag is deprecated and rejected on a fresh 3.5 installation; subscription and authorization settings are part of the MaaS interface.

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

### Gateway Hostname Discovery

OpenShift AI 3.5 discovers the MaaS API through `/v1/tenants`, which prefers the first ready **HTTPS listener**. The Gateway deployment above already advertises the external Route hostname on both HTTP and HTTPS. Verify it:

```bash
oc get gateway maas-default-gateway -n openshift-ingress \
  -o custom-columns=NAME:.spec.listeners[*].name,HOSTNAME:.spec.listeners[*].hostname
```

The gateway manifest also includes a second HTTPS listener, `https-router`, **after** `https` and without a hostname restriction. Keep this fallback: the re-encrypting OpenShift Router's backend TLS connection must match it. Restricting every HTTPS listener to the external hostname causes `503` responses with `filter_chain_not_found` in the gateway logs. Leaving only HTTP with an external hostname causes tenant discovery to fail and the API Keys page to report `maas-api is not available`.

The 3.4 workaround that sets `MAAS_API_URL` on `rhods-dashboard` is no longer part of this setup. Refresh the OpenShift AI dashboard after configuration. We verify the API key UI and usage dashboard in Chapters 4 and 5.

### GPU Time-Slicing (Single Physical GPU Only)

First inspect GPU capacity:

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

If the cluster already has at least two free schedulable GPUs, skip this section. The 3.5.1 validation cluster has four L4 GPUs and does not need time-slicing.

For a cluster with one physical NVIDIA L4 GPU, this tutorial deploys two small models side by side on that GPU. By default Kubernetes treats each physical GPU as a single schedulable resource, so only one model pod could claim it. GPU time-slicing makes the node advertise 2 virtual GPUs, allowing both pods to be scheduled and share the physical GPU's memory and compute.

Apply the time-slicing ConfigMap:

```bash
oc apply -f chapter-1/gpu-time-slicing.yml
```

Patch the ClusterPolicy to reference it:

```bash
oc patch clusterpolicy gpu-cluster-policy --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"l4"}}}}'
```

Wait for the device plugin pod to restart (this takes ~30 seconds):

```bash
oc rollout status daemonset/nvidia-device-plugin-daemonset -n nvidia-gpu-operator --timeout=120s
```

Verify the node now advertises 2 GPUs (the device plugin may take a few seconds to update allocatable resources after restart):

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

Expected output: the GPU node advertises `2` schedulable GPUs. Do not wait on the first node: it might be a control-plane node without a GPU.

### Verify script

Run the verification script to confirm every component is healthy:

```bash
./chapter-1/7-verify-maas.sh
```

It checks the cluster connection, OpenShift AI version, operator health, Kuadrant readiness, MaaS component and tenant state, user workload monitoring, database availability, Gateway programming status, llm-d prerequisites, Authorino TLS, dashboard flags, and the external MaaS endpoint — printing a pass/fail for each. Every check must pass before Chapter 2. The installer runs this script automatically.

---

## Troubleshooting: OpenShift AI Dashboard Unavailable

If the OpenShift AI Dashboard stops loading (while the OpenShift Console still works), the most likely cause is the Istio gateway proxy pods being **OOMKilled**. Kuadrant's Wasm policy filters consume more memory than the default 1Gi limit allows.

Check the gateway pods:

```bash
oc get pods -n openshift-ingress -l 'gateway.networking.k8s.io/gateway-name'
```

If you see `CrashLoopBackOff`, describe the pod to confirm `OOMKilled`:

```bash
oc get pods -n openshift-ingress -l 'gateway.networking.k8s.io/gateway-name' -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

**Fix:** Increase the memory limit on both gateway infrastructure ConfigMaps. The `gw-options` ConfigMap applied in this chapter already includes a 2Gi deployment override. For the `data-science-gateway-config` (managed by the OpenShift AI platform operator), apply the same override:

```bash
oc patch configmap data-science-gateway-config -n openshift-ingress --type merge -p '{"data":{"deployment":"spec:\n  template:\n    spec:\n      containers:\n      - name: istio-proxy\n        resources:\n          limits:\n            cpu: \"2\"\n            memory: 2Gi\n          requests:\n            cpu: 100m\n            memory: 128Mi\n"}}'
```

Then restart the affected gateway deployments to pick up the new limits:

```bash
oc rollout restart deployment -n openshift-ingress -l 'gateway.istio.io/managed'
```

---

Once everything is verified, proceed to [Chapter 2](../chapter-2/README.md).
