# Chapter 4: API Access & Adding a Second Model

With the model deployed and governance active, it's time to generate API keys, test access, and expand the catalog with a second model that only `department-b` can use.

## Step 1: Generate an API Key

### If the Dashboard says `maas-api is not available`

Check the dashboard MaaS backend logs:

```bash
oc logs deployment/maas-ui -n redhat-ods-applications --tail=10
```

If discovery of `/v1/tenants` returns `500` with `Unable to determine external hostname from Gateway status`, correct the Chapter 1 gateway listeners. The HTTP hostname alone is insufficient: discovery prefers HTTPS. With the updated repository, reapply the gateway (including its unrestricted `https-router` fallback), then advertise the external hostname:

```bash
export GW_CLASS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.gatewayClassName}')
envsubst < chapter-1/3-gateway.yml | oc apply -f -
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
oc patch gateway maas-default-gateway -n openshift-ingress --type=json \
  -p="[{\"op\":\"add\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"$ROUTE_HOST\"},{\"op\":\"add\",\"path\":\"/spec/listeners/1/hostname\",\"value\":\"$ROUTE_HOST\"}]"
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=300s
./chapter-1/7-verify-maas.sh
```

The dashboard retries discovery every 30 seconds. After the logs show `MaaS API URL discovered after retry`, refresh **Gen AI Studio → API Keys** and continue below. Other discovery errors require checking the logged cause; this correction specifically addresses the missing external hostname.

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
MAAS_API_KEY=$(curl -sS -k --fail-with-body --max-time 60 -X POST https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"department-a-test","subscription":"standard-plan"}' \
  | jq -er '.key // error(tostring) | select(type == "string" and startswith("sk-oai-"))') && export MAAS_API_KEY
```

After either option, retain the department-a key for Chapter 5:

```bash
: "${MAAS_API_KEY:?API key creation failed; check the API response and group membership}"
export MAAS_API_KEY_A=$MAAS_API_KEY
```

Keep this terminal open. Keys are shown only at creation; if you start a new shell, re-export the saved values. Do not replace a working key with the literal placeholder in the Dashboard option.

## Step 2: Test Model Access

List available models:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq
```

Send a test request. Use `"stream": true` — non-streaming requests still return an empty body on the tested 3.5.1 gateway (see [KNOWN-ISSUES.md](../KNOWN-ISSUES.md)). The pipeline extracts the answer from the streamed `data:` chunks, omitting metadata and the `[DONE]` marker:

```bash
curl -fsS -k -N --max-time 60 -X POST https://$ROUTE_HOST/ai-models/granite-2b/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-2b",
    "messages": [{"role": "user", "content": "Say hello!"}],
    "max_tokens": 50,
    "stream": true
  }' \
  | sed -n '/^data: {/s/^data: //p' \
  | jq --unbuffered -j '.choices[]?.delta.content // empty'
printf '\n'
```

Expected output (wording may vary):

```text
Hello! How can I assist you today?
```

## Step 3: Deploy the Second Model (TinyLlama)

Both models run simultaneously using separate schedulable GPUs, or GPU time-slicing if you configured a single-GPU cluster in Chapter 1.

```bash
oc apply -f chapter-4/tinyllama-data-connection.yml
oc apply -f chapter-4/tinyllama-inference-service.yml
oc apply -f chapter-4/tinyllama-maas-model-ref.yml
```

Wait for deployment:

```bash
oc wait llminferenceservice/tinyllama -n ai-models --for=condition=Ready --timeout=1200s
```

The `MaaSModelRef` can remain unready until the governance pairing is applied in the next step.

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
oc wait maasmodelref/tinyllama -n ai-models --for=condition=Ready --timeout=300s
oc wait maassubscription/limited-plan maasauthpolicy/limited-access \
  -n models-as-a-service --for=condition=Ready --timeout=300s
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
"publishers/ai-models/models/granite-2b"
```

Prove that direct inference is denied too; hiding a model from the catalog alone is insufficient:

```bash
curl -sS -k --max-time 60 -o /dev/null -w 'department-a → TinyLlama HTTP:%{http_code}\n' \
  https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY_A" \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Say hello!"}],"max_tokens":20,"stream":true}'
```

Expected: `HTTP:403`.

### Move your user to department-b

```bash
oc adm groups remove-users department-a $(oc whoami)
oc adm groups add-users department-b $(oc whoami)
```

Before creating the new key, verify that the MaaS API sees the new membership. OpenShift authentication/group caches can briefly retain the previous groups after `oc adm groups` succeeds:

```bash
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
oc get groups department-a department-b
curl -fsS -k --max-time 60 -H "Authorization: Bearer $(oc whoami -t)" \
  https://$ROUTE_HOST/maas-api/v1/models \
  | jq -r '.data[].subscriptions[]?.name' | sort -u
```

Expected: your username appears only in `department-b`, and the API prints `limited-plan`. If the API still prints `standard-plan` or nothing, wait about a minute and repeat the check. Continue once it prints `limited-plan`. If it remains missing, check that `MaaSSubscription/limited-plan` and `MaaSAuthPolicy/limited-access` are Ready as described in Step 4.

### Create a Fresh API Key

API keys capture group membership at creation time, so you **must** create a new key after switching groups. Keep the department-a key for the showback comparison in Chapter 5; revoke both test keys after finishing the tutorial.

**Option A — Dashboard:** Create a new key in **Gen AI Studio → API Keys** named `department-b-test` on the **limited-plan** subscription.

**Option B — CLI:**

```bash
MAAS_API_KEY=$(curl -sS -k --fail-with-body --max-time 60 -X POST https://$ROUTE_HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"department-b-test","subscription":"limited-plan"}' \
  | jq -er '.key // error(tostring) | select(type == "string" and startswith("sk-oai-"))') && export MAAS_API_KEY
```

The CLI command reports the API's JSON error instead of hiding it behind `curl: (22)`. A `400` with `"code":"invalid_subscription"` means `limited-plan` cannot be resolved for the identity seen by the API. Recheck the group and API visibility above, then rerun key creation once `limited-plan` is visible. Do not continue with an empty key.

If you used the Dashboard, paste the new key instead:

```bash
export MAAS_API_KEY="sk-oai-..."  # paste your new key
```

After either option, save the department-b key separately:

```bash
: "${MAAS_API_KEY:?API key creation failed; check the API response and group membership}"
export MAAS_API_KEY_B=$MAAS_API_KEY
```

### Verify department-b sees both models

Run the same curl command again:

```bash
curl -s -k -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq '.data[].id'
```

Expected output — both models now visible:

```
"publishers/ai-models/models/granite-2b"
"publishers/ai-models/models/tinyllama"
```

The MaaS API lists canonical model IDs (`publishers/ai-models/models/...`), while the inference examples above continue to accept the short served-model names.

Verify actual inference succeeds for department-b on both models. Keep the static JSON single-quoted so zsh treats `!` literally; only `$MODEL` needs double quotes for expansion:

```bash
for MODEL in granite-2b tinyllama; do
  curl -sS -k --max-time 60 -o /dev/null -w "$MODEL HTTP:%{http_code}\n" \
    https://$ROUTE_HOST/ai-models/$MODEL/v1/chat/completions \
    -H "Authorization: Bearer $MAAS_API_KEY_B" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Say hello!"}],"max_tokens":20,"stream":true}'
done
```

Expected: two `HTTP:200` responses. Keep both `$MAAS_API_KEY_A` and `$MAAS_API_KEY_B` for the showback demo.

In OpenShift AI 3.5.1, administrators manage subscriptions and authorization policies under **Settings → MaaS governance**.

Proceed to [Chapter 5: Usage & Showback](../chapter-5/README.md).
