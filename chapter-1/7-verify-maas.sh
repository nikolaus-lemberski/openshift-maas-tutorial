#!/bin/bash

echo "=== MaaS Prerequisites Verification ==="
echo ""

# 1. OpenShift Version
echo "1. OpenShift Platform Version:"
OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion' 2>/dev/null || echo "ERROR")
echo "   Version: ${OCP_VERSION}"
[[ "${OCP_VERSION}" == "ERROR" ]] && echo "   ❌ FAILED" || echo "   ✅ PASSED"
echo ""

# 2. OpenShift AI Operator
echo "2. Red Hat OpenShift AI Operator:"
RHOAI_CSV=$(oc get csv -n redhat-ods-applications 2>/dev/null | grep rhods-operator | awk '{print $1}')
echo "   CSV: ${RHOAI_CSV:-NOT FOUND}"
[[ -z "${RHOAI_CSV}" ]] && echo "   ❌ FAILED" || echo "   ✅ PASSED"
echo ""

# 3. Red Hat Connectivity Link / Kuadrant Operator
echo "3. Red Hat Connectivity Link / Kuadrant Operator:"
RCL_CSV=$(oc get csv -A 2>/dev/null | grep -E "connectivity-link|kuadrant-operator|rhcl-operator" | awk '{print $2}' | head -1)
echo "   CSV: ${RCL_CSV:-NOT FOUND}"
KUADRANT_STATUS=$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "ERROR")
echo "   Kuadrant Ready: ${KUADRANT_STATUS}"
[[ "${KUADRANT_STATUS}" == "True" ]] && echo "   ✅ PASSED" || echo "   ❌ FAILED"
echo ""

# 4. Llama Stack Operator
echo "4. Llama Stack Operator:"
LLAMA_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.llamastackoperator.managementState}' 2>/dev/null || echo "ERROR")
echo "   Management State: ${LLAMA_STATE}"
[[ "${LLAMA_STATE}" == "Managed" ]] && echo "   ✅ PASSED" || echo "   ⚠️  WARNING: Required for dashboard features"
echo ""

# 5. User Workload Monitoring
echo "5. User Workload Monitoring:"
UWM_ENABLED=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -o "enableUserWorkload: true" || echo "NOT ENABLED")
echo "   Status: ${UWM_ENABLED}"
[[ "${UWM_ENABLED}" == "enableUserWorkload: true" ]] && echo "   ✅ PASSED" || echo "   ❌ FAILED"
echo ""

# 6. PostgreSQL Database Secret
echo "6. PostgreSQL Database Secret:"
DB_SECRET=$(oc get secret maas-db-config -n redhat-ods-applications -o jsonpath='{.metadata.name}' 2>/dev/null || echo "NOT FOUND")
echo "   Secret: ${DB_SECRET}"
[[ "${DB_SECRET}" == "maas-db-config" ]] && echo "   ✅ PASSED" || echo "   ❌ FAILED"
echo ""

# 7. Gateway API
echo "7. Gateway API Resources:"
GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "NOT FOUND")
echo "   Gateway Programmed: ${GW_STATUS}"
[[ "${GW_STATUS}" == "True" ]] && echo "   ✅ PASSED" || echo "   ❌ FAILED"
echo ""

# 8. KServe Component
echo "8. KServe Component (Required for MaaS):"
KSERVE_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || echo "ERROR")
echo "   Management State: ${KSERVE_STATE}"
[[ "${KSERVE_STATE}" == "Managed" ]] && echo "   ✅ PASSED" || echo "   ❌ FAILED"
echo ""

echo "=== Summary ==="
echo "Review any ❌ FAILED items above before proceeding with MaaS deployment."
echo ""