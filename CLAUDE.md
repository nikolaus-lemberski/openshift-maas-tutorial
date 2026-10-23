# OpenShift AI — Models as a Service Tutorial

A step-by-step tutorial for setting up a governed AI platform on OpenShift AI using Models as a Service (MaaS). Two departments get different levels of access and token quotas to shared LLMs.

## Project structure

```
Part 1: Install and configure (administrator)
chapter-1/   Base infrastructure and early model start; check-prereqs.sh before install
chapter-2/   Groups and initial governance
chapter-3/   Register both models, complete governance, wait for readiness; then observability.md and api-keys.md

Part 2: Use MaaS (administrator as both departments)
chapter-4/   Discovery, inference, and selective access with the two demonstration keys
chapter-5/   AI ops usage/showback (Technology Preview); no installation
chapter-6/   AI ops quota tuning, HTTP 429s, and model observability
```

Each chapter has a `README.md` with prose and copy-pasteable commands. Follow the root README reading order. YAML lives in the chapter that applies it: Chapter 1 owns model connections/services and observability operators; Chapter 2 owns initial governance; Chapter 3 owns both MaaSModelRefs and the TinyLlama governance updates. Observability operators stay in `chapter-1/` YAML and are applied from `chapter-3/observability.md`. Part 2 chapters are README-only. The default walkthrough uses the logged-in administrator as both departments. Chapter 4 uses the two keys from `chapter-3/api-keys.md` and does not change groups or deploy resources.

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
- Built-in OpenShift AI observability (COO, OpenTelemetry, AI-managed Perses backend)
- Prometheus / Thanos Querier (metrics)
