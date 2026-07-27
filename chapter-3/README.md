# Chapter 3: Deploying the First Model

With governance in place, it's time to deploy a model. You'll deploy **Granite 3.3 2B Instruct** into the `ai-models` namespace using the `LLMInferenceService` CRD (llm-d distributed inference).

Key points:
- Models **must** use `LLMInferenceService` to integrate with MaaS governance — legacy KServe `InferenceService` bypasses MaaS entirely
- A `MaaSModelRef` resource registers the model with the MaaS gateway
- Once the model is ready, the subscriptions and auth policies from Chapter 2 activate automatically

## Before you deploy

If you have not already done so in Chapter 1, free the GPU by scaling down the Demo Platform's default model:

```bash
oc scale deployment llama-32-3b-instruct-predictor -n my-first-model --replicas=0
```

If that deployment does not exist, skip this step.

## Step 1: Create the Data Connection

This stores the OCI registry location so the Dashboard can display the model:

```bash
oc apply -f chapter-3/granite-data-connection.yml
```

## Step 2: Deploy the Model

```bash
oc apply -f chapter-3/granite-inference-service.yml
```

## Step 3: Register with MaaS

The `MaaSModelRef` links the model to the MaaS gateway, enabling subscription-based access control:

```bash
oc apply -f chapter-3/granite-maas-model-ref.yml
```

## Step 4: Wait for Deployment

The model takes a few minutes to pull weights and initialize. Monitor progress:

```bash
oc get llminferenceservice granite-2b -n ai-models -w
```

You can also watch in the OpenShift AI Dashboard under **AI Hub → Models → Deployments** in the `ai-models` project.

## Step 5: Verify

Check the model is registered with MaaS:

```bash
oc get maasmodelref -n ai-models
```

Expected output:

```
NAME         PHASE   ENDPOINT         HTTPROUTE       GATEWAY           AGE
granite-2b   Ready   http://maas...   granite-2b...   maas-default...   5m
```

Check that subscriptions are now active:

```bash
oc get maassubscription -n models-as-a-service
```

Proceed to [Chapter 4](../chapter-4/README.md).
