# OpenShift AI — Models as a Service Tutorial

This tutorial walks you through setting up a fully governed AI platform using OpenShift AI's Models as a Service (MaaS) capabilities. Two departments (`department-a` and `department-b`) get different levels of access and token quotas to shared AI models.

Validated on OpenShift AI **3.5.2**, OpenShift **4.20.42**, and Red Hat Connectivity Link **1.4.3**. OpenShift AI is a prerequisite; its installed Subscription controls automatic updates.

The tutorial has two parts. **Part 1** installs and governs the platform. **Part 2** uses two API keys — one per department — from the same administrator terminal. Stop and resolve failed checks before continuing.

For a repeat presentation after setup, use the [demo runbook](DEMO.md). See [known issues and validation limits](KNOWN-ISSUES.md) for the tested configuration and platform workarounds.

The optional `./chapter-1/install.sh` installs the base infrastructure; add `--with-models` to submit both model services. Groups, governance, the AI observability stack, and the demonstration API keys still require the remaining Part 1 steps. See the [installer options](chapter-1/README.md#install-for-a-demo). `./cleanup.sh` removes those tutorial resources without uninstalling OpenShift AI or GPU operators.

This is a **3.5** walkthrough. Configuration paths differ from the 3.4 documentation; see the [version comparison](chapter-1/README.md#version-compatibility).

## What you will build

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

## Part 1: Install and configure

**Audience:** cluster administrators, platform engineers, and AI ops administrators. Use an administrator Bash terminal from the repository root. Start with `./chapter-1/check-prereqs.sh`, then follow these steps in order:

| Order | Guide | Outcome |
|---|---|---|
| 1 | [Install the base infrastructure](chapter-1/README.md) | Operators, Gateway, Authorino TLS, PostgreSQL, MaaS API, and base telemetry configured |
| 2 | [Start the model downloads](chapter-1/README.md#start-the-model-downloads) | Both model services submitted; downloads and initialization continue during governance setup |
| 3 | [Configure groups and governance](chapter-2/README.md) | Department groups, subscriptions, and authorization policies created |
| 4 | [Publish models, configure observability, and create API keys](chapter-3/README.md) | Both models registered and ready, final access matrix configured, Usage dashboard available, and one API key per subscription retained for Part 2 |

Steps 1–2 are Chapter 1, step 3 is Chapter 2, and step 4 is Chapter 3. Step 2 submits the model services without waiting for readiness; Kubernetes downloads and starts them while you configure groups and governance in step 3. Chapter 3 registers the models with MaaS, checks readiness, enables observability, and creates the demonstration keys.

Part 1 is complete when both models and governance resources are ready, the Usage dashboard is available, and both demonstration keys exist. Operator readiness alone is not enough.

## Part 2: Use MaaS

**Audience:** the same administrator, acting as a model consumer and then as AI ops. Start here after both demonstration keys exist.

| Order | Guide | Outcome |
|---|---|---|
| 1 | [Use your API keys](chapter-4/README.md) | Model discovery, inference, and selective access verified for both departments |
| 2 | [Observe usage and export showback](chapter-5/README.md) | Subscription and model usage compared, with usage CSV exported (Technology Preview) |
| 3 | [Operate token budgets](chapter-6/README.md) | Quota adjusted, 429 responses and metrics verified, and quota restored |

Keep the keys through showback, quota exercises, or a presentation, then revoke them with the [key cleanup](chapter-3/README.md#cleanup).

