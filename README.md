# OpenShift AI — Models as a Service Tutorial

This tutorial walks you through setting up a fully governed AI platform using OpenShift AI's Models as a Service (MaaS) capabilities. Two departments (`department-a` and `department-b`) get different levels of access and token quotas to shared AI models.

Tested on OpenShift AI **3.5.1**, OpenShift **4.20.41**, and Red Hat Connectivity Link **1.4.3**. OpenShift AI is a prerequisite; its installed Subscription controls automatic updates.

Start with [Chapter 1 prerequisites](chapter-1/README.md#prerequisites), then complete Chapters 1–6 in order. Run commands from this repository's root in a Bash shell, keeping the same terminal open so exported API keys carry across chapters. Choose one option where a step offers Dashboard or CLI alternatives. Stop and resolve failed checks before continuing.

For a repeat presentation after setup, use the [demo runbook](DEMO.md). See [known issues and validation limits](KNOWN-ISSUES.md) for the tested configuration and platform workarounds.

For a demo audience that wants to start with MaaS governance, an admin can run `./chapter-1/install.sh` to configure and verify Chapter 1, then continue with Chapter 2. See the [installer prerequisites and options](chapter-1/README.md#install-for-a-demo).

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
          |   Observability   |     <-- OpenShift AI built-in dashboards
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
| [5](chapter-5/README.md) | **Usage & Showback (Technology Preview)** | Embedded OpenShift AI dashboard, per-model and subscription usage, CSV export |
| [6](chapter-6/README.md) | **Observability & Rate Limiting** | Demonstrate token limits, HTTP 429s, and built-in AI observability |


