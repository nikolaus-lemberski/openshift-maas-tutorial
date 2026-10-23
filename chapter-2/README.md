# Part 1 — Chapter 2: Configure groups and governance

**Role:** cluster administrator. Complete [Chapter 1](../chapter-1/README.md), including [starting the model downloads](../chapter-1/README.md#start-the-model-downloads), first.

While the models initialize, configure **who** can access **which** models and **how much** they can consume. `ai-models` and both model services already exist; do not wait for readiness here.

| Resource | Purpose |
|---|---|
| **MaaSSubscription** | Token quotas: which models a group can use and at what rate |
| **MaaSAuthPolicy** | Authorizes requests to those model endpoints |

> [!IMPORTANT]
> Both are required. A subscription without an auth policy results in `403 Forbidden`.

## Step 1: Create the OpenShift groups

Create two department groups and add the logged-in administrator to both. This walkthrough uses one administrator identity for both departments. Each API key you create later is bound to one subscription, so membership in both groups does not merge the two access levels.

```bash
oc adm groups new department-a
oc adm groups new department-b
oc adm groups add-users department-a "$(oc whoami)"
oc adm groups add-users department-b "$(oc whoami)"
```

## Step 2: Deploy the subscriptions

Each department gets a subscription with different **per-user, per-subscription, per-model** token limits. Multiple keys for the same user share that budget; a new key does not reset it.

`priority` chooses the default subscription only when a key is created without naming one.

> [!NOTE]
> The `granite-2b` model service is submitted, but its `MaaSModelRef` is created in Chapter 3. Subscriptions can show `Failed` until that reference exists. That does not stop the backend download.

```bash
oc apply -f chapter-2/subscriptions.yml
```

Verify:

```bash
oc get maassubscription -n models-as-a-service
```

Expected output:

```
NAME            PHASE    PRIORITY   AGE
limited-plan    Failed   10         8s
standard-plan   Failed   50         8s
```

Inspect the reason before accepting this temporary state:

```bash
oc get maassubscription standard-plan limited-plan -n models-as-a-service -o json \
  | jq '.items[] | {name: .metadata.name, phase: .status.phase, ready: (.status.conditions[]? | select(.type=="Ready") | .message), models: [.status.modelRefStatuses[]? | .message]}'
```

Expected for each subscription:

```
{
  "name": "...",
  "phase": "Failed",
  "ready": "all 1 model references are invalid or unavailable",
  "models": [
    "MaaSModelRef ai-models/granite-2b not found"
  ]
}
```

Continue only if `models` identifies the `ai-models/granite-2b` MaaS model reference as missing or not ready. Authentication, admission, or other reconciliation errors need resolving now. A `Failed` phase alone is insufficient evidence of the expected dependency.

## Step 3: Deploy the authorization policies

```bash
oc apply -f chapter-2/auth-policies.yml
```

Verify:

```bash
oc get maasauthpolicy -n models-as-a-service
```

Expected output:

```
NAME              PHASE    AGE
limited-access    Failed   9s
standard-access   Failed   9s
```

Immediately after apply, the policies can show `Pending` for several seconds while the gateway `AuthPolicy` `maas-gateway-auth` catches up to a new generation. Re-check until both are `Failed`.

Check the authorization policy conditions too:

```bash
oc get maasauthpolicy standard-access limited-access -n models-as-a-service -o json \
  | jq '.items[] | {name: .metadata.name, phase: .status.phase, ready: (.status.conditions[]? | select(.type=="Ready") | .message)}'
```

Expected `ready` message for both: `all 1 model references are invalid or missing`. Authorization policies do not list per-model status; that message (the single Granite reference) is the only failure expected at this point. Chapter 3 registers both models and waits for the model services, policies, and subscriptions to become ready.

## Verification

```bash
oc get groups department-a department-b
```

Confirm both groups exist and list your username. Continue to [Chapter 3](../chapter-3/README.md).
