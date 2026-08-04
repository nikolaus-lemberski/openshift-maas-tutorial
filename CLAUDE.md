# OpenShift AI — Models as a Service Tutorial

A step-by-step tutorial for setting up a governed AI platform on OpenShift AI using Models as a Service (MaaS). Two departments get different levels of access and token quotas to shared LLMs.

## Project structure

```
chapter-1/   Infrastructure setup (operators, gateway, database, MaaS API)
chapter-2/   Governance (groups, subscriptions, auth policies)
chapter-3/   Model deployment (Granite 2B via LLMInferenceService)
chapter-4/   API access & multi-model (API keys, TinyLlama, selective access)
chapter-5/   Observability & rate limiting (telemetry, metrics, Perses dashboards)
```

Each chapter has a `README.md` with prose + copy-pasteable commands and numbered YAML manifests applied in order.

## Writing conventions

- Every shell command and YAML manifest is meant to be copy-pasted verbatim by the reader.
- Use `$VAR` instead of `${VAR}` in shell commands and `envsubst`-templated YAML. Some Mac terminals mangle braces during copy-paste. Only use `${VAR}` when the shell genuinely requires it (parameter expansion operators like `${VAR:-default}`, or disambiguation like `${VAR}_suffix`).
- Scripts on disk (e.g. `7-verify-maas.sh`) are not affected by the brace rule, but new code should still prefer `$VAR`.
- YAML manifests use `.yml` extension.
- README sections follow the pattern: explanation of what/why, then a fenced `bash` code block, then verification commands and expected output.

## Tech stack

- OpenShift / Kubernetes (oc CLI, CRDs, operators, OLM)
- OpenShift AI (DataScienceCluster, KServe, MaaS CRs)
- Red Hat Connectivity Link / Kuadrant (Gateway API, Authorino, Limitador)
- vLLM model servers (Granite 2B, TinyLlama)
- PostgreSQL (MaaS API database)
- Perses (dashboards as CRDs via Cluster Observability Operator)
- Prometheus / Thanos Querier (metrics)
