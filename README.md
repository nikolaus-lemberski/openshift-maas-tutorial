# OpenShift AI — Models as a Service Tutorial

This tutorial walks you through setting up a fully governed AI platform using OpenShift AI's Models as a Service (MaaS) capabilities. Two departments (`department-a` and `department-b`) get different levels of access and token quotas to shared AI models.

## What You'll Build

```
   department-a          department-b
  (API key, quota)      (API key, quota)
        |                      |
        +----------+-----------+
                   |
                   v
          +-------------------+
          |  Gateway + MaaS   |     <-- auth policies, rate limits
          |  API  (Kuadrant)  |         (Authorino, Limitador)
          +-------------------+
             |            |
             v            v
        +--------+   +----------+
        | Granite|   | TinyLlama|      <-- shared vLLM model servers
        |   2B   |   |          |
        +--------+   +----------+
             |            |
             +-----+------+
                   v
          +-------------------+
          |   Observability   |     <-- Prometheus, Perses dashboards
          +-------------------+
```

> [!NOTE]
>
> Granite 2B and TinyLlama are small models chosen for the demo to keep GPU requirements low. The same gateway, governance, and observability pattern applies to production workloads with larger models.



## Tutorial Chapters


| Chapter                  | Topic                             | What you'll do                                                       |
| ------------------------ | --------------------------------- | -------------------------------------------------------------------- |
| [1](chapter-1/README.md) | **Infrastructure Setup**          | Install operators, configure gateway, enable MaaS API layer          |
| [2](chapter-2/README.md) | **Governance**                    | Create groups, subscriptions, and authorization policies             |
| [3](chapter-3/README.md) | **Model Deployment**              | Deploy Granite 2B via LLMInferenceService                            |
| [4](chapter-4/README.md) | **API Access & Multi-Model**      | Generate API keys, deploy TinyLlama, configure selective access      |
| [5](chapter-5/README.md) | **Observability & Rate Limiting** | Telemetry, metrics, load testing, rate limits, and Perses dashboards |


