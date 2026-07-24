# Chapter 2: Governance Setup

Before deploying any models, we establish the governance layer that controls **who** can access **which** models and **how much** they can consume.

OpenShift AI MaaS uses two custom resources working together:

| Resource | Purpose |
|---|---|
| **MaaSSubscription** | Defines token quotas — which models a group can use and at what rate |
| **MaaSAuthPolicy** | Grants network access — physically authorizes traffic through the API gateway |

> **Both are required.** A subscription without an auth policy results in `403 Forbidden` errors.

## Step 1: Create the OpenShift Groups

Create two department groups:

```bash
oc adm groups new department-a
oc adm groups new department-b
```

Add your current user to `department-a`:

```bash
oc adm groups add-users department-a $(oc whoami)
```

## Step 2: Create the Models Namespace

```bash
oc new-project ai-models
```

## Step 3: Deploy the Subscriptions

Each department gets a subscription with different token limits. The `priority` field determines which subscription takes precedence when a user belongs to multiple groups.

> **Note:** The subscriptions reference `granite-2b` which doesn't exist yet. They will show a `Failed` phase — this is expected and resolves automatically once the model is deployed in Chapter 3.

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
standard-plan   Failed   50         8s
limited-plan    Failed   10         8s
```

## Step 4: Deploy the Authorization Policies

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
standard-access   Failed   9s
limited-access    Failed   9s
```

The `Failed` state is expected — it resolves once the referenced model is deployed.

## Verification

```bash
echo "=== Groups ===" && \
oc get groups | grep department && \
echo "=== department-a Membership ===" && \
oc get group department-a -o jsonpath='{.users[*]}' && echo
```

Confirm your groups exist and your username appears under `department-a`. Then proceed to [Chapter 3](../chapter-3/README.md).
