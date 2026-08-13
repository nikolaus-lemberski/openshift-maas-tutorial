# Chapter 4: API Access & Adding a Second Model

With the model deployed and governance active, it's time to generate API keys, test access, and expand the catalog with a second model that only `department-b` can use.

## Step 1: Generate an API Key

**Option A — Dashboard**

1. In the OpenShift AI Dashboard, go to **Gen AI Studio → API Keys**
2. Click **Create API key**
3. Name it `department-a-test`
4. Select **standard-plan** from the Subscription dropdown
5. Click **Create** and **copy the key immediately** (it starts with `sk-oai-` and is shown only once)

```bash
export MAAS_API_KEY="sk-oai-..."  # paste your key
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
```

**Option B — CLI**

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
export MAAS_API_KEY=$(curl -s -k -X POST https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"department-a-test","subscription":"standard-plan"}' | jq -r .key)
echo $MAAS_API_KEY
```

The key is shown only once — save the value before continuing.

## Step 2: Test Model Access

List available models:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq
```

Send a test request:

```bash
curl -s -k -X POST https://$ROUTE_HOST/ai-models/granite-2b/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-2b",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 50,
    "stream": true,
    "stream_options": {"include_usage": true}
  }'
```

## Step 3: Deploy the Second Model (TinyLlama)

Thanks to GPU time-slicing (configured in Chapter 1), both models run simultaneously on the single GPU — no need to scale anything down.

```bash
oc apply -f chapter-4/tinyllama-data-connection.yml
oc apply -f chapter-4/tinyllama-inference-service.yml
oc apply -f chapter-4/tinyllama-maas-model-ref.yml
```

Monitor deployment:

```bash
oc get llminferenceservice tinyllama -n ai-models -w
```

Verify both models are running:

```bash
oc get llminferenceservice -n ai-models
```

Expected output — both models `Ready`:

```
NAME         READY   AGE
granite-2b   True    30m
tinyllama    True    2m
```

## Step 4: Grant department-b Access to TinyLlama

The TinyLlama model is deployed but no one has access yet. Two resources need updating — the **MaaSSubscription** (token quotas) and the **MaaSAuthPolicy** (network access). Both must reference a model for a group to actually reach it.

### Before (Chapter 2 setup)

Both departments can only reach Granite:

```
                        ┌──────────────┐
                        │  granite-2b  │
                        └──────┬───────┘
                               │
              ┌────────────────┼────────────────┐
              │                                 │
   ┌──────────┴──────────┐          ┌───────────┴──────────┐
   │   standard-plan     │          │    limited-plan       │
   │   50,000 tok/min    │          │    2,000 tok/min      │
   └──────────┬──────────┘          └───────────┬──────────┘
              │                                 │
   ┌──────────┴──────────┐          ┌───────────┴──────────┐
   │   standard-access   │          │    limited-access     │
   │   (auth policy)     │          │    (auth policy)      │
   └──────────┬──────────┘          └───────────┬──────────┘
              │                                 │
     ┌────────┴────────┐              ┌─────────┴────────┐
     │  department-a   │              │   department-b   │
     └─────────────────┘              └──────────────────┘
```

### After (this step)

`department-b` gains access to TinyLlama with its own rate limit. `department-a` stays unchanged:

```
          ┌──────────────┐              ┌──────────────┐
          │  granite-2b  │              │   tinyllama   │
          └──────┬───────┘              └──────┬───────┘
                 │                             │
    ┌────────────┼──────────────┬──────────────┘
    │            │              │
    │   ┌────────┴──────────┐   │
    │   │   limited-plan    │   │
    │   │  granite: 2k t/m  │   │
    │   │  tiny: 1k tok/m   │   │
    │   └────────┬──────────┘   │
    │            │              │
    │   ┌────────┴──────────┐   │
    │   │  limited-access   │   │
    │   │  (auth policy)    │   │
    │   └────────┬──────────┘   │
    │            │              │
    │   ┌────────┴────────┐     │
    │   │  department-b   │     │
    │   └─────────────────┘     │
    │                           │
    │  ┌─────────────────────┐  │
    │  │   standard-plan     │  │
    │  │  granite: 50k t/m   │  │
    │  │  (no tiny access)   │  │
    │  └─────────┬───────────┘  │
    │            │              │
    │  ┌─────────┴───────────┐  │
    │  │  standard-access    │  │
    │  │  (auth policy)      │  │
    │  └─────────┬───────────┘  │
    │            │              │
    │  ┌─────────┴─────────┐    │
    │  │   department-a    │    │
    │  └───────────────────┘    │
    │                           │
```

### What exactly changes

| Resource | What changed |
|---|---|
| `limited-plan` (subscription) | Added `tinyllama` model ref with 1,000 tok/min limit |
| `limited-access` (auth policy) | Added `tinyllama` to `modelRefs` so traffic is allowed through the gateway |
| `standard-plan` | **No change** — department-a still only sees Granite |
| `standard-access` | **No change** |

### Apply the updates

```bash
oc apply -f chapter-4/subscriptions-updated.yml
oc apply -f chapter-4/auth-policies-updated.yml
```

> **Why does the "limited" plan get more models?** The names `standard` and `limited` refer to the *token budget*, not the model catalog. `department-b` gets a lower rate limit (2,000 vs 50,000 tokens/min on Granite) but access to an additional model. In a real environment you'd name plans to match your organization's structure.

## Step 5: Test Selective Access

The goal: prove that the gateway enforces per-group model visibility.

```
  ┌──────────────────┐          ┌──────────────────┐
  │   department-a   │          │   department-b   │
  │ (standard-plan)  │          │  (limited-plan)  │
  └────────┬─────────┘          └────────┬─────────┘
           │                             │
      Lists models:                 Lists models:
      • granite-2b                  • granite-2b
                                    • tinyllama
```

### Confirm department-a can only see Granite

Your user is still in `department-a` with the API key from Step 2. List the models:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq '.data[].id'
```

Expected output — only Granite:

```
"granite-2b"
```

### Move your user to department-b

```bash
oc adm groups remove-users department-a $(oc whoami)
oc adm groups add-users department-b $(oc whoami)
```

### Revoke and recreate the API key

API keys capture group membership at creation time, so you **must** create a new key after switching groups.

**Option A — Dashboard:** Revoke the old key in **Gen AI Studio → API Keys**, then create a new one named `department-b-test` on the **limited-plan** subscription.

**Option B — CLI:**

```bash
export MAAS_API_KEY=$(curl -s -k -X POST https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"department-b-test","subscription":"limited-plan"}' | jq -r .key)
echo $MAAS_API_KEY
```

If you used the Dashboard, paste the new key instead:

```bash
export MAAS_API_KEY="sk-oai-..."  # paste your new key
```

### Verify department-b sees both models

Run the same curl command again:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq '.data[].id'
```

Expected output — both models now visible:

```
"granite-2b"
"tinyllama"
```

Proceed to [Chapter 5](../chapter-5/README.md).
