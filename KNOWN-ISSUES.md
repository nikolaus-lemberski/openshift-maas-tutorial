# Known Platform Issues

**Environment tested:** OpenShift 4.20.32, RHOAI/rhods-operator 3.4.3, rhcl-operator v1.4.2 (Granite 2B, TinyLlama via `LLMInferenceService` + `InferencePool`/EPP)

## Rate limiting needs vLLM's `--enable-force-include-usage`

Without this flag, MaaS token rate limiting silently doesn't work: the Kuadrant Wasm shim reads `usage.total_tokens` from the response to track consumption, but plain streaming responses don't include a `usage` object unless the client opts in with `stream_options.include_usage` — something you can't rely on callers to do. Confirmed on this platform version: 10 requests against a 100 tok/min budget all returned `200`, never a `429`, with gateway logs showing `Missing json property: /usage/total_tokens`.

[Chapter 3](chapter-3/README.md) and [chapter-4](chapter-4/README.md) deploy both models with `--enable-force-include-usage` from the start, which makes vLLM always emit `usage` regardless of client request shape. Verified fix: same 10-request burst now returns `1×200` then `9×429`.

## Non-streaming requests return an empty body

Plain (non-streaming) `chat/completions` calls through the MaaS gateway return `HTTP 200` with a 0-byte body — the model server itself is fine, but the gateway's per-model EPP `ext_proc` filter conflicts with the Kuadrant Wasm shim's context handling for buffered responses. This is a platform issue, not fixable via vLLM flags or MaaS manifests. Every `chat/completions` example in this tutorial uses `"stream": true` to work around it.
