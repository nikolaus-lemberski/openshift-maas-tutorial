# Part 2 — Chapter 4: Use MaaS with your API keys

**Role:** model consumer, played by the administrator from Part 1. You have both keys from [creating demonstration API keys](../chapter-3/README.md#step-7-create-demonstration-api-keys). You will not install components or deploy models here.

| Department | Subscription | Available models | Token limits per user |
|---|---|---|---|
| `department-a` | `standard-plan` | Granite | 50,000/min |
| `department-b` | `limited-plan` | Granite and TinyLlama | Granite 2,000/min; TinyLlama 1,000/min |

Use the same terminal that created the keys. The commands below use `$MAAS_API_KEY`, so you select a department by pointing it at one of the two keys. Run Steps 1–3 with the department-a key, then again with the department-b key. Client TLS is already configured from the key setup. If a key is lost or expired, recreate it in this terminal:

```bash
eval "$(./chapter-3/create-api-key.sh department-a)"
eval "$(./chapter-3/create-api-key.sh department-b)"
```

Run only the line for the missing key; the script revokes the old key with the same name.

## Select the department-a key

```bash
export MAAS_API_KEY=$MAAS_API_KEY_A
```

## Step 1: Discover your models

```bash
curl -fsS --max-time 60 -H "Authorization: Bearer $MAAS_API_KEY" \
  https://$ROUTE_HOST/maas-api/v1/models | jq '.data[] | {id, url}'
```

`standard-plan` lists only `publishers/ai-models/models/granite-2b`. `limited-plan` lists that ID and `publishers/ai-models/models/tinyllama`. The API returns canonical IDs; the inference calls below use the short served-model names. The returned `url` is useful when connecting applications to other deployments.

## Step 2: Call Granite

```bash
curl -fsS --max-time 60 \
  https://$ROUTE_HOST/ai-models/granite-2b/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"granite-2b","messages":[{"role":"user","content":"Say hello!"}],"max_tokens":50}' \
  | jq -r '.choices[0].message.content'
```

Expected: a greeting such as `Hello! How can I assist you today?` A successful status without generated text is insufficient; investigate errors before continuing.

> [!NOTE]
> If the command prints nothing or `jq` reports a parse error, your cluster has the [empty-body bug](../KNOWN-ISSUES.md#non-streaming-requests-return-an-empty-body) of OpenShift AI 3.5.1 and earlier: non-streaming responses through the gateway arrive empty. Request a streamed response instead, and add `"stream":true` to every chat request in Chapters 4–6:
>
> ```bash
> curl -fsS -N --max-time 60 \
>   https://$ROUTE_HOST/ai-models/granite-2b/v1/chat/completions \
>   -H "Authorization: Bearer $MAAS_API_KEY" \
>   -H 'Content-Type: application/json' \
>   -d '{"model":"granite-2b","messages":[{"role":"user","content":"Say hello!"}],"max_tokens":50,"stream":true}' \
>   | sed -n '/^data: {/s/^data: //p' \
>   | jq --unbuffered -j '.choices[]?.delta.content // empty'
> printf '\n'
> ```

## Step 3: Verify selective access

Send the same TinyLlama request with the selected key:

```bash
curl -sS --max-time 60 -o /dev/null -w 'TinyLlama HTTP:%{http_code}\n' \
  https://$ROUTE_HOST/ai-models/tinyllama/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Say hello!"}],"max_tokens":20}'
```

Expected: department-a receives **403**; department-b receives **200**. This tests direct endpoint enforcement as well as catalog visibility. No model deployment or policy change is needed during this exercise.

## Select the department-b key

```bash
export MAAS_API_KEY=$MAAS_API_KEY_B
```

Repeat [Steps 1–3](#step-1-discover-your-models). Expected: the catalog lists Granite and TinyLlama, Granite returns a greeting, and TinyLlama returns **200**.

Continue to [Chapter 5: Usage and showback](../chapter-5/README.md). After Chapters 5–6, revoke the keys with the [key cleanup](../chapter-3/README.md#cleanup).
