# Chapter 4: API Access & Adding a Second Model

With the model deployed and governance active, it's time to generate API keys, test access, and expand the catalog with a second model that only `department-b` can use.

## API Key Security

By default, users can create permanent API keys. Enforce a 90-day maximum lifetime:

```bash
oc patch tenant default-tenant -n models-as-a-service \
  --type merge \
  -p '{"spec":{"apiKeys":{"maxExpirationDays":90}}}'
```

> **Important:** API keys capture a snapshot of the user's group memberships at creation time. If a user is later removed from a group, their existing keys **continue to work** until revoked or expired. Always revoke keys after group changes.

## Step 1: Generate an API Key

1. In the OpenShift AI Dashboard, go to **Gen AI Studio → API Keys**
2. Click **Create API key**
3. Name it `department-a-test`
4. Select **standard-plan** from the Subscription dropdown
5. Click **Create** and **copy the key immediately** (it starts with `sk-oai-` and is shown only once)

## Step 2: Test Model Access

```bash
export MAAS_API_KEY="sk-oai-..."  # paste your key
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
```

List available models:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq
```

Send a test request:

```bash
curl -s -k -X POST https://$ROUTE_HOST/ai-models/llama-3-8b/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-8b",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 50
  }' | jq
```

## Step 3: Deploy the Second Model (Qwen3-4b)

### Free the GPU

If your lab has a single GPU, scale down Llama first:

```bash
oc patch llminferenceservice llama-3-8b -n ai-models --type=merge \
  -p '{"spec":{"replicas":0}}'
```

Wait for the GPU to be released. Watch the workload deployment specifically, not all pods in the namespace:

```bash
oc get deployment llama-3-8b-kserve -n ai-models -w
```

> **Note:** `LLMInferenceService` also runs a separate `*-router-scheduler` pod (routing/scheduling only). It keeps running and does **not** hold a GPU, so seeing it stay `Running` is expected and not a sign the scale-down failed. You can confirm the GPU is free with:
>
> ```bash
> oc describe nodes | grep -A2 "Allocated resources" 
> ```

### Deploy Qwen

```bash
oc apply -f chapter-4/qwen-data-connection.yml
oc apply -f chapter-4/qwen-inference-service.yml
oc apply -f chapter-4/qwen-maas-model-ref.yml
```

Monitor deployment:

```bash
oc get llminferenceservice qwen3-4b -n ai-models -w
```

## Step 4: Grant department-b Access to Qwen

The Qwen model is deployed but no one has access yet. Update the subscriptions and auth policies to give `department-b` access to Qwen while keeping `department-a` restricted to Llama only:

```bash
oc apply -f chapter-4/subscriptions-updated.yml
oc apply -f chapter-4/auth-policies-updated.yml
```

> **Note:** `department-a` (standard-access) keeps access to `llama-3-8b` only. `department-b` (limited-access) now has access to **both** `llama-3-8b` and `qwen3-4b`.

## Step 5: Test Selective Access

Switch your user to `department-b` to verify the governance works:

```bash
oc adm groups remove-users department-a $(oc whoami)
oc adm groups add-users department-b $(oc whoami)
```

Revoke your old API key in the Dashboard (**Gen AI Studio → API Keys**), then create a new one:

1. Click **Create API key**
2. Name it `department-b-test`
3. Select **limited-plan**
4. Copy the key

Test that you can see the Qwen model:

```bash
export MAAS_API_KEY="sk-oai-..."  # paste your new key
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq
```

You should see `qwen3-4b` listed. A `standard-plan` key would only show `llama-3-8b`.

Proceed to [Chapter 5](../chapter-5/README.md).
