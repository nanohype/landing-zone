#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
ADDON_ROLES=$(jq -r '.pod_identity_role_arns.value | to_entries[] | select(.value != null) | "\(.key) \(.value)"' outputs.json)
S3_BUCKETS=$(jq -r '.s3_bucket_names.value | to_entries[] | select(.value != null) | "\(.key) \(.value)"' outputs.json)

# =============================================================================
# AWS Resources (provisioned by this component)
# =============================================================================

# --- Pod Identity Roles ---
echo "Checking addon Pod Identity roles..."
while IFS=' ' read -r ADDON ROLE_ARN; do
  ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
  ROLE_STATUS=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$ROLE_STATUS" == "NOT_FOUND" ]]; then
    echo "FAIL: role for '${ADDON}' not found (${ROLE_ARN})"
    exit 1
  fi
  echo "  ${ADDON}: role exists (${ROLE_NAME})"
done <<< "$ADDON_ROLES"

# --- S3 Buckets ---
echo "Checking S3 buckets..."
while IFS=' ' read -r ADDON BUCKET; do
  if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "FAIL: S3 bucket for '${ADDON}' not found (${BUCKET})"
    exit 1
  fi

  PUBLIC_ACCESS=$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "false")
  if [[ "$PUBLIC_ACCESS" != "True" ]]; then
    echo "FAIL: S3 bucket '${BUCKET}' does not have public access blocked"
    exit 1
  fi
  echo "  ${ADDON}: bucket exists, public access blocked (${BUCKET})"
done <<< "$S3_BUCKETS"

# =============================================================================
# In-Cluster Addons (deployed by ArgoCD via eks-gitops)
# =============================================================================

# Helper: check that a deployment has at least 1 available replica
check_deployment() {
  local ns=$1 name=$2 label=$3
  local avail
  avail=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  avail=${avail:-0}
  if [[ "$avail" -eq 0 ]]; then
    echo "FAIL: ${label} deployment has 0 available replicas"
    exit 1
  fi
  echo "  ${label}: ${avail} available replicas"
}

# Helper: check that a daemonset has all pods ready
check_daemonset() {
  local ns=$1 name=$2 label=$3
  local ready desired
  ready=$(kubectl get daemonset "$name" -n "$ns" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  desired=$(kubectl get daemonset "$name" -n "$ns" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  desired=${desired:-0}
  if [[ "$ready" -eq 0 ]]; then
    echo "FAIL: ${label} daemonset has 0 ready pods"
    exit 1
  fi
  echo "  ${label}: ${ready}/${desired} ready"
}

# Helper: check that a statefulset has ready replicas
check_statefulset() {
  local ns=$1 name=$2 label=$3
  local ready
  ready=$(kubectl get statefulset "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  if [[ "$ready" -eq 0 ]]; then
    echo "FAIL: ${label} statefulset has 0 ready replicas"
    exit 1
  fi
  echo "  ${label}: ${ready} ready replicas"
}

# --- cert-manager ---
echo "Checking cert-manager..."
check_deployment cert-manager cert-manager "cert-manager"
check_deployment cert-manager cert-manager-webhook "cert-manager-webhook"
check_deployment cert-manager cert-manager-cainjector "cert-manager-cainjector"

# --- external-secrets ---
echo "Checking external-secrets..."
check_deployment external-secrets external-secrets "external-secrets"
check_deployment external-secrets external-secrets-webhook "external-secrets-webhook"
check_deployment external-secrets external-secrets-cert-controller "external-secrets-cert-controller"

# --- aws-load-balancer-controller ---
echo "Checking aws-load-balancer-controller..."
check_deployment kube-system aws-load-balancer-controller "alb-controller"

# --- external-dns ---
echo "Checking external-dns..."
check_deployment external-dns external-dns "external-dns"

# --- kyverno ---
echo "Checking kyverno..."
check_deployment kyverno kyverno-admission-controller "kyverno-admission"
check_deployment kyverno kyverno-background-controller "kyverno-background"
check_deployment kyverno kyverno-reports-controller "kyverno-reports"

# --- loki ---
echo "Checking loki..."
check_statefulset monitoring loki "loki"
check_deployment monitoring loki-gateway "loki-gateway"

# --- tempo ---
echo "Checking tempo..."
check_statefulset monitoring tempo "tempo"

# --- grafana-agent ---
echo "Checking grafana-agent..."
check_daemonset monitoring grafana-agent "grafana-agent"

# --- karpenter ---
echo "Checking karpenter..."
check_deployment kube-system karpenter "karpenter"

# --- keda ---
echo "Checking keda (if deployed)..."
if kubectl get deployment keda-operator -n keda &>/dev/null; then
  check_deployment keda keda-operator "keda-operator"
  check_deployment keda keda-operator-metrics-apiserver "keda-metrics-server"
else
  echo "  keda: not deployed (skipped)"
fi

# --- velero ---
echo "Checking velero (if deployed)..."
if kubectl get deployment velero -n velero &>/dev/null; then
  check_deployment velero velero "velero"
else
  echo "  velero: not deployed (skipped)"
fi

# --- opencost ---
echo "Checking opencost (if deployed)..."
if kubectl get deployment opencost -n opencost &>/dev/null; then
  check_deployment opencost opencost "opencost"
else
  echo "  opencost: not deployed (skipped)"
fi

# --- argo-rollouts ---
echo "Checking argo-rollouts..."
check_deployment argo-rollouts argo-rollouts "argo-rollouts"

# --- argo-events ---
echo "Checking argo-events (if deployed)..."
if kubectl get deployment argo-events-controller-manager -n argo-events &>/dev/null; then
  check_deployment argo-events argo-events-controller-manager "argo-events"
else
  echo "  argo-events: not deployed (skipped)"
fi

# --- argo-workflows ---
echo "Checking argo-workflows (if deployed)..."
if kubectl get deployment argo-workflows-server -n argo-workflows &>/dev/null; then
  check_deployment argo-workflows argo-workflows-server "argo-workflows-server"
  check_deployment argo-workflows argo-workflows-workflow-controller "argo-workflows-controller"
else
  echo "  argo-workflows: not deployed (skipped)"
fi

echo "PASS: all cluster-addons checks passed"
