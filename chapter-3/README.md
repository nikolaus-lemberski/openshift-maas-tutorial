# Chapter 3: Deploying the First Model

With governance in place, it's time to deploy a model. You'll deploy **Llama-3-8b** into the `ai-models` namespace using the `LLMInferenceService` CRD (llm-d distributed inference).

Key points:
- Models **must** use `LLMInferenceService` to integrate with MaaS governance — legacy KServe `InferenceService` bypasses MaaS entirely
- A `MaaSModelRef` resource registers the model with the MaaS gateway
- Once the model is ready, the subscriptions and auth policies from Chapter 2 activate automatically

## Step 1: Create the Data Connection

This stores the OCI registry location so the Dashboard can display the model:

```bash
oc apply -f chapter-3/llama-data-connection.yml
```

## Step 2: Deploy the Model

```bash
oc apply -f chapter-3/llama-inference-service.yml
```

## Step 3: Register with MaaS

The `MaaSModelRef` links the model to the MaaS gateway, enabling subscription-based access control:

```bash
oc apply -f chapter-3/llama-maas-model-ref.yml
```

## Step 4: Wait for Deployment

The model takes **10–15 minutes** to pull weights and initialize. Monitor progress:

```bash
oc get llminferenceservice llama-3-8b -n ai-models -w
```

You can also watch in the OpenShift AI Dashboard under **AI Hub → Models → Deployments** in the `ai-models` project.

## Step 5: Verify

Check the model is registered with MaaS:

```bash
oc get maasmodelref -n ai-models
```

Expected output:

```
NAME         MODELREF_KIND         MODELREF_NAME   READY   AGE
llama-3-8b   LLMInferenceService   llama-3-8b      True    5m
```

Check that subscriptions are now active:

```bash
oc get maassubscription -n models-as-a-service
```

Proceed to [Chapter 4](../chapter-4/README.md).
