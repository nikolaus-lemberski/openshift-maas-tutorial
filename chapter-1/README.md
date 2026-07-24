# Chapter 1: Infrastructure Setup

> **Complete this chapter first.** All subsequent chapters assume the infrastructure below is installed and working.

## Prerequisites

- OpenShift AI with GPU — install from [Demo Platform](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.openshift-ai-v3.prod&utm_source=webapp&utm_medium=share-link)
- `oc` CLI logged in as a cluster admin
- `envsubst` available locally (typically provided by `gettext`)

## Enabling MaaS

Models-as-a-Service (MaaS) exposes LLMs through managed API endpoints with subscription-based governance — token quotas, rate limits, and API key authentication. Setting it up requires a policy engine, an API gateway, a database, and a few OpenShift AI feature flags. The sections below walk through each component.

### Red Hat Connectivity Link Operator

MaaS relies on the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) for routing and policy enforcement. [Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.0/html-single/introduction_to_connectivity_link/index) (built on the [Kuadrant](https://kuadrant.io/) project) is the supported Gateway API provider — it supplies authentication, authorization, and rate-limiting policies that MaaS attaches to model endpoints.

```bash
oc apply -f chapter-1/0-connectivity-link.yml
```

This creates the `kuadrant-system` namespace, an OperatorGroup, and a Subscription that installs the operator from the Red Hat catalog.

Wait for the operator to be ready:

```bash
until oc get csv -n kuadrant-system 2>/dev/null | grep -q rhcl-operator; do sleep 5; done
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n kuadrant-system -l operators.coreos.com/rhcl-operator.kuadrant-system --timeout=300s
```

### Kuadrant

With the operator installed, create a Kuadrant instance. This deploys the control-plane components — [Authorino](https://github.com/Kuadrant/authorino) (auth) and [Limitador](https://github.com/Kuadrant/limitador) (rate limiting) — that enforce policies on Gateway API resources.

```bash
oc apply -f chapter-1/1-kuadrant.yml
```

Wait for Kuadrant to become ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
```

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
```

#### Deploy the Gateway

Create the Gateway with HTTP (80) and HTTPS (443) listeners that accept routes from all namespaces. The `kuadrant.io/gateway: "true"` label tells Kuadrant to watch this Gateway for policy attachments, and the `security.opendatahub.io/authorino-tls-bootstrap: "true"` annotation triggers automatic EnvoyFilter creation so the Gateway trusts Authorino's TLS certificate.

```bash
envsubst < chapter-1/3-gateway.yml | oc apply -f -
```

### Route

In environments without **DNSPolicy** or MetalLB there is no external load balancer to assign an IP to the Gateway's ClusterIP service. An OpenShift Route bridges the gap by fronting the Gateway through the default OpenShift Router (HAProxy), giving it a publicly reachable hostname with re-encrypted TLS.

```bash
envsubst < chapter-1/4-route.yml | oc apply -f -
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
```

### MaaS API Layer

Enable the two DataScienceCluster components that power MaaS:

- **`llamastackoperator`** — deploys the Llama Stack Operator, which manages agentic and RAG workflow components (inference, embeddings, vector stores).
- **`kserve.modelsAsService`** — deploys the MaaS controller, which reconciles MaaS custom resources (Tenant, MaaSSubscription, MaaSAuthPolicy, MaaSModelRef) and wires up the API layer.

Both default to `Removed`; setting them to `Managed` opts in.

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "llamastackoperator": {
        "managementState": "Managed"
      },
      "kserve": {
        "modelsAsService": {
          "managementState": "Managed"
        }
      }
    }
  }
}'
```

### User Workload Monitoring

OpenShift's built-in monitoring stack only scrapes platform components by default. MaaS tracks token consumption and model usage through Prometheus metrics emitted by user workloads. Enabling user workload monitoring deploys a dedicated Prometheus instance in `openshift-user-workload-monitoring` that scrapes ServiceMonitor/PodMonitor targets in user namespaces — making those metrics available for the MaaS observability dashboard.

```bash
oc apply -f chapter-1/6-user-workload-monitoring.yml
```

### Enable GenAI Studio

Toggle three feature flags in the OpenShift AI dashboard configuration:

- **`genAiStudio`** — shows the *Gen AI Studio* menu in the left-hand navigation.
- **`modelAsService`** — adds the MaaS interface (AI asset endpoints, API key management) inside Gen AI Studio.
- **`maasAuthPolicies`** — surfaces the *Subscription* and *Authorization policies* settings in the admin area.

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {
    "dashboardConfig": {
      "modelAsService": true,
      "genAiStudio": true,
      "maasAuthPolicies": true
    }
  }
}'
```

### MaaS Routing Patch

The OpenShift AI dashboard needs to know the external URL of the MaaS API so it can proxy requests from the browser. We capture the hostname of the Route created earlier and inject it as an environment variable into the dashboard Deployment.

```bash
oc wait --for=condition=Available deployment/rhods-dashboard -n redhat-ods-applications --timeout=300s
```

Capture the external Route URL and inject it into the Dashboard:

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
oc set env deployment/rhods-dashboard -n redhat-ods-applications MAAS_API_URL=https://$ROUTE_HOST/maas-api
```

Wait for the Dashboard to restart with the new variable (this may take 1–2 minutes):

```bash
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications
```

Refresh your OpenShift AI browser window. The Gen AI Studio - API Key generation tab menu option will now appear in your left-hand navigation pane.

The menu options for Subscription and Authorization policies will appear in the Settings section of the OpenShift AI dashboard.

### Verify script

Run the verification script to confirm every component is healthy:

```bash
./chapter-1/7-verify-maas.sh
```

It checks the OpenShift version, operator CSVs, Kuadrant readiness, Llama Stack state, user workload monitoring, the database secret, Gateway programming status, and KServe — printing a pass/fail for each.

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
