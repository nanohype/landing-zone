#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
CILIUM_VERSION=$(jq -r '.cilium_version.value' outputs.json)
ARGOCD_NS=$(jq -r '.argocd_namespace.value' outputs.json)

# --- Cilium ---
echo "Checking Cilium (expected version: ${CILIUM_VERSION})..."
CILIUM_DS_READY=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
CILIUM_DS_DESIRED=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
if [[ "$CILIUM_DS_READY" -eq 0 ]]; then
  echo "FAIL: Cilium daemonset has 0 ready pods"
  exit 1
fi
if [[ "$CILIUM_DS_READY" -ne "$CILIUM_DS_DESIRED" ]]; then
  echo "FAIL: Cilium daemonset ready=${CILIUM_DS_READY} desired=${CILIUM_DS_DESIRED}"
  exit 1
fi
echo "  Cilium daemonset ready (${CILIUM_DS_READY}/${CILIUM_DS_DESIRED} pods)"

# --- Cilium Operator ---
echo "Checking Cilium operator..."
CILIUM_OP_AVAIL=$(kubectl get deployment cilium-operator -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "$CILIUM_OP_AVAIL" -eq 0 ]]; then
  echo "FAIL: Cilium operator has 0 available replicas"
  exit 1
fi
echo "  Cilium operator available (${CILIUM_OP_AVAIL} replicas)"

# --- CoreDNS ---
echo "Checking CoreDNS..."
COREDNS_AVAIL=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "$COREDNS_AVAIL" -eq 0 ]]; then
  echo "FAIL: CoreDNS has 0 available replicas"
  exit 1
fi
echo "  CoreDNS available (${COREDNS_AVAIL} replicas)"

# --- kube-proxy ---
echo "Checking kube-proxy..."
KP_READY=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ "$KP_READY" -eq 0 ]]; then
  echo "FAIL: kube-proxy has 0 ready pods"
  exit 1
fi
echo "  kube-proxy ready (${KP_READY} pods)"

# --- ArgoCD Namespace ---
echo "Checking ArgoCD namespace '${ARGOCD_NS}'..."
NS_STATUS=$(kubectl get namespace "$ARGOCD_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")
if [[ "$NS_STATUS" != "Active" ]]; then
  echo "FAIL: namespace '${ARGOCD_NS}' status is '${NS_STATUS}'"
  exit 1
fi
echo "  Namespace '${ARGOCD_NS}' is Active"

# --- ArgoCD Server ---
echo "Checking ArgoCD server..."
ARGOCD_AVAIL=$(kubectl get deployment argocd-server -n "$ARGOCD_NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "$ARGOCD_AVAIL" -eq 0 ]]; then
  echo "FAIL: ArgoCD server has 0 available replicas"
  exit 1
fi
echo "  ArgoCD server available (${ARGOCD_AVAIL} replicas)"

# --- ArgoCD Repo Server ---
echo "Checking ArgoCD repo server..."
REPO_AVAIL=$(kubectl get deployment argocd-repo-server -n "$ARGOCD_NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "$REPO_AVAIL" -eq 0 ]]; then
  echo "FAIL: ArgoCD repo server has 0 available replicas"
  exit 1
fi
echo "  ArgoCD repo server available (${REPO_AVAIL} replicas)"

# --- ArgoCD Application Controller ---
echo "Checking ArgoCD application controller..."
CTRL_READY=$(kubectl get statefulset argocd-application-controller -n "$ARGOCD_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$CTRL_READY" -eq 0 ]]; then
  echo "FAIL: ArgoCD application controller has 0 ready replicas"
  exit 1
fi
echo "  ArgoCD application controller ready (${CTRL_READY} replicas)"

# --- Network config ConfigMap ---
# The eks-gitops scheme-aware Kyverno load-balancer subnet-injection policy reads
# this at admission time; it must exist on every cluster (both modes) or that
# mutation fails its context lookup.
echo "Checking kube-system/network-config ConfigMap..."
NET_MODE=$(kubectl get configmap network-config -n kube-system -o jsonpath='{.data.network_mode}' 2>/dev/null || echo "NOT_FOUND")
if [[ "$NET_MODE" != "create" && "$NET_MODE" != "adopt" ]]; then
  echo "FAIL: network-config ConfigMap missing or network_mode is '${NET_MODE}' (expected create or adopt)"
  exit 1
fi
echo "  network-config present (network_mode=${NET_MODE})"

echo "PASS: all cluster-bootstrap checks passed"
