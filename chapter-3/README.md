# Part 1 — Chapter 3: Finish model publishing and verify readiness

**Role:** cluster administrator. Complete Chapter 1's [model downloads](../chapter-1/README.md#start-the-model-downloads) and [Chapter 2](../chapter-2/README.md) first.

This chapter finishes Part 1 in three pages. Work through them in order:

1. **This page:** register both models with MaaS, complete TinyLlama access, and wait for Ready.
2. [Configure observability](observability.md): metrics stack, user labels, and the Usage dashboard.
3. [Create demonstration API keys](api-keys.md): one key per department, used throughout Part 2.

Run commands from the repository root.

The manifests use `LLMInferenceService` with the MaaS Gateway, one GPU each, and `--enable-force-include-usage` so streamed responses also report token usage for rate limiting. Do not substitute a legacy `InferenceService` without MaaS integration.

## Step 1: Register both models with MaaS

Confirm both model services were submitted, then create their `MaaSModelRef` resources:

```bash
oc get llminferenceservice granite-2b tinyllama -n ai-models
oc apply -f chapter-3/granite-maas-model-ref.yml \
  -f chapter-3/tinyllama-maas-model-ref.yml
```

If either service is missing, return to [Start the model downloads](../chapter-1/README.md#start-the-model-downloads). Registration can reconcile while the backends are still initializing; readiness is checked below. Chapter 2's Granite subscriptions and authorization policies can now resolve their model reference.

## Step 2: Complete the access matrix

The updated manifests add TinyLlama to `limited-plan` and `limited-access`. Both resources must include the model: a subscription supplies its quota and an authorization policy permits gateway access.

| Department | Subscription | Granite tokens/min per user | TinyLlama tokens/min per user |
|---|---|---|---|
| `department-a` | `standard-plan` | 50,000 | No access |
| `department-b` | `limited-plan` | 2,000 | 1,000 |

```bash
oc apply -f chapter-3/subscriptions-updated.yml
oc apply -f chapter-3/auth-policies-updated.yml
```

## Step 3: Wait for readiness

Wait for image pulls and initialization if they did not finish during Chapter 2:

```bash
oc wait llminferenceservice/granite-2b llminferenceservice/tinyllama \
  -n ai-models --for=condition=Ready --timeout=1200s
oc wait maasmodelref/granite-2b maasmodelref/tinyllama \
  -n ai-models --for=condition=Ready --timeout=300s
oc wait maassubscription/standard-plan maassubscription/limited-plan \
  maasauthpolicy/standard-access maasauthpolicy/limited-access \
  -n models-as-a-service --for=condition=Ready --timeout=300s
oc get llminferenceservice -n ai-models
oc get maasmodelref -n ai-models
```

Expected: both services, both model references, and every governance wait succeed. On timeout:

```bash
oc get pods -n ai-models
oc get events -n ai-models --sort-by=.lastTimestamp
```

`Pending` often means insufficient GPU/CPU/memory. `ImagePullBackOff` is registry or pull-credential failure. Stop until the checks pass.

You can also watch **AI Hub → Models → Deployments** in `ai-models`.

Continue to page 2: [Configure observability](observability.md).
