# Chapter 5: Token Rate Limiting in Action

Each `MaaSSubscription` defines a per-model **token budget** — the maximum number of tokens a user can consume within a rolling time window. When the budget is exhausted the gateway returns `429 Too Many Requests` until the window resets. In this chapter you'll see that enforcement first-hand.

## Step 1: Understand What MaaS Created

When you applied the subscriptions in Chapters 2 and 4, the MaaS controller translated each `tokenRateLimits` entry into a Kuadrant `TokenRateLimitPolicy` attached to the model's HTTPRoute. These are the policies that actually enforce the limits at the gateway.

List them:

```bash
oc get tokenratelimitpolicy -A
```

Expected output:

```
NAMESPACE           NAME                   AGE
ai-models           maas-trlp-granite-2b   ...
ai-models           maas-trlp-tinyllama    ...
openshift-ingress   gateway-default-deny   ...
```

Inspect the Granite policy to see how subscription limits map to Kuadrant primitives:

```bash
oc get tokenratelimitpolicy maas-trlp-granite-2b -n ai-models -o json \
  | jq -r '.spec.limits | to_entries[] | "\(.key): \(.value.rates[0].limit) tok / \(.value.rates[0].window)"'
```

Expected output — the 50,000 tok/min (standard-plan) and 2,000 tok/min (limited-plan) values from your `MaaSSubscription` resources:

```
models-as-a-service-limited-plan-granite-2b-tokens: 2000 tok / 1m
models-as-a-service-standard-plan-granite-2b-tokens: 50000 tok / 1m
```

> **Do not edit these resources directly.** The MaaS controller reconciles them from your `MaaSSubscription` definitions. Manual changes will be overwritten.

## Step 2: Tighten the Limit for the Demo

The limited-plan allows 1,000 tokens per minute on TinyLlama. That's generous enough that a few short requests won't trigger it. Lower it to **500 tokens per minute** so you can hit the ceiling within two or three requests:

```bash
oc patch maassubscription limited-plan -n models-as-a-service --type=json \
  -p '[{"op": "replace", "path": "/spec/modelRefs/1/tokenRateLimits/0/limit", "value": 500}]'
```

Verify the MaaS controller updated the underlying policy:

```bash
oc get tokenratelimitpolicy maas-trlp-tinyllama -n ai-models -o json \
  | jq -r '.spec.limits | to_entries[] | "\(.key): \(.value.rates[0].limit) tok / \(.value.rates[0].window)"'
```

Expected output:

```
models-as-a-service-limited-plan-tinyllama-tokens: 500 tok / 1m
```

## Step 3: Hit the Token Limit

Make sure your environment variables are still set from Chapter 4 (you should be a `department-b` user with a `limited-plan` key):

```bash
export MAAS_API_KEY="sk-oai-..."  # your department-b key from Chapter 4
export ROUTE_HOST=$(oc get route openshift-ai-inference -n openshift-ingress -o jsonpath='{.spec.host}')
```

Run the following command a few times in quick succession. It prints the HTTP status code, the `Retry-After` header (if present), and the token usage from each response:

```bash
RESPONSE=$(curl -s -k -w '\n%{http_code}' \
  -X POST https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tinyllama",
    "messages": [{"role": "user", "content": "Write a short paragraph about the history of bread."}],
    "max_tokens": 300
  }')
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "HTTP $HTTP_CODE"
echo "$BODY" | jq '{tokens: .usage} // {error: .}' 2>/dev/null || echo "$BODY"
```

The first request should succeed and show the token usage:

```
HTTP 200
{
  "tokens": {
    "prompt_tokens": 18,
    "completion_tokens": 276,
    "total_tokens": 294
  }
}
```

The `total_tokens` value is what gets counted against your 500 tok/min budget. Run the same command again immediately — once the budget is exhausted you'll see:

```
HTTP 429
```

The gateway rejects the request before it reaches the model server. Wait for the 1-minute window to reset, then run it again to confirm it succeeds with `200`.

## Step 4: Restore the Original Limit

Reset TinyLlama back to 1,000 tokens per minute:

```bash
oc patch maassubscription limited-plan -n models-as-a-service --type=json \
  -p '[{"op": "replace", "path": "/spec/modelRefs/1/tokenRateLimits/0/limit", "value": 1000}]'
```

## Key Takeaways

| Concept | Detail |
|---|---|
| **What is being limited** | Actual tokens consumed (extracted from the `usage.total_tokens` field in each response), not request count |
| **Where enforcement happens** | At the gateway, via Kuadrant `TokenRateLimitPolicy` — the model server never sees rejected requests |
| **Who manages the policies** | The MaaS controller — you define limits in `MaaSSubscription`, MaaS translates them into Kuadrant CRDs |
| **What the client sees** | HTTP `429 Too Many Requests` with a `Retry-After` header |

---

Proceed to [Chapter 6](../chapter-6/README.md).
