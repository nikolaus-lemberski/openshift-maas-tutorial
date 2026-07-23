# Chapter 1: Infrastructure Setup

> **Complete this chapter first.** All subsequent chapters assume the infrastructure below is installed and working.

## Prerequisites

- OpenShift AI with GPU — install from [Demo Platform](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.openshift-ai-v3.prod&utm_source=webapp&utm_medium=share-link)
- `oc` CLI logged in as a cluster admin
- `envsubst` available locally (typically provided by `gettext`)

## Enabling MaaS

### Red Hat Connectivity Link Operator

```bash
oc apply -f chapter-1/0-connectivity-link.yml
```

Wait for the operator to be ready:

```bash
until oc get csv -n kuadrant-system 2>/dev/null | grep -q rhcl-operator; do sleep 5; done
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n kuadrant-system -l operators.coreos.com/rhcl-operator.kuadrant-system --timeout=300s
```

### Kuadrant

```bash
oc apply -f chapter-1/1-kuadrant.yml
```

Wait for Kuadrant to become ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
```

### Gateway

TLS certificate

```bash
oc apply -f chapter-1/2-gw-service-tls-cm.yml
```

Get the Gateway class

```bash
export GW_CLASS=$(oc get gatewayclass -o custom-columns=NAME:.metadata.name,CTRL:.spec.controllerName --no-headers | grep "openshift.io/gateway-controller" | awk '{print $1}' | head -n 1)
```

Deploy the Gateway

```bash
envsubst < chapter-1/3-gateway.yml | oc apply -f -
```

### Route

Expose Gateway via Route (as we do not use **DNSPolicy** and do not have MetalLB to create a cloud **Loadbalancer**)

```bash
envsubst < chapter-1/4-route.yml | oc apply -f -
```

### Configure Authorino

Set SSL environment variables for outbound communication:

```bash
oc -n kuadrant-system set env deployment/authorino \
SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

Generate the TLS certificate for Authorino:

```bash
oc annotate service authorino-authorino-authorization -n kuadrant-system \
service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
```

Patch the Authorino resource to enable the TLS listener:

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

```bash
oc apply -f chapter-1/5-maas-db.yml
```

### MaaS API Layer

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

```bash
oc apply -f chapter-1/6-user-workload-monitoring.yml
```

### Enable GenAI Studio

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

Tell the dashboard how to route traffic to the MaaS API.

```bash
oc wait --for=condition=Available deployment/rhods-dashboard -n redhat-ods-applications --timeout=300s
```

Capture the external Route URL and inject it into the Dashboard:

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
oc set env deployment/rhods-dashboard -n redhat-ods-applications MAAS_API_URL=https://${ROUTE_HOST}/maas-api
```

Wait for the Dashboard to restart with the new variable (this may take 1–2 minutes):

```bash
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications
```

Refresh your OpenShift AI browser window. The Gen AI Studio - API Key generation tab menu option will now appear in your left-hand navigation pane.

The menu options for Subscription and Authorization policies will appear in the Settings section of the OpenShift AI dashboard.

### Verify script

Check if everything is set up:

```bash
./chapter-1/7-verify-maas.sh
```

---

Once everything is verified, proceed to [Chapter 2](../chapter-2/README.md).
