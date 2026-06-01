#!/usr/bin/env bash
#
# Manual end-to-end validation of the nanohype stack on a REAL AWS account:
# provision the substrate, install the operator, deploy one tenant through
# GitOps, assert real-IRSA conformance + cloudgov, then tear everything down.
#
# Triggered BY HAND ONLY (task e2e / the workflow_dispatch button) — never on a
# schedule — because each run provisions real, billable AWS (EKS + NAT +
# Graviton nodes, roughly $0.30-0.60 for the ~30-45 min run). Teardown ALWAYS
# runs via an EXIT trap, so a failure (or Ctrl-C) never leaves billing on.
#
# Prereqs: AWS creds for the target account (AWS_PROFILE or CI OIDC), Bedrock
# Claude access in the region, kubectl/helm/terragrunt/tofu/jq/docker-buildx/go,
# the sibling eks-agent-platform + cloudgov repos on disk, and git auth to push
# to the tenants repo (SSH key locally; a token-credential helper in CI).
#
set -euo pipefail

# --- config (env-overridable; defaults target the cheap dev tree) -----------
: "${E2E_ACCOUNT_ID:?set E2E_ACCOUNT_ID (the real 12-digit AWS account)}"
REGION="${E2E_REGION:-us-west-2}"
ENVIRONMENT="${E2E_ENV:-dev}"
ACCOUNT_DIR="${E2E_ACCOUNT_DIR:-workload-dev}"
CLUSTER="${E2E_CLUSTER:-dev-eks}"
TENANT="${E2E_TENANT:-e2e-smoke}"
TENANTS_REPO="${E2E_TENANTS_REPO:-git@github.com:nanohype/tenants.git}"
# Default to the stxkxs profile only when AWS_PROFILE is UNSET (local runs); in
# CI it's set empty so the OIDC env credentials are used instead of a profile.
AWS_PROFILE="${AWS_PROFILE-stxkxs}"
if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else unset AWS_PROFILE; fi
export AWS_REGION="$REGION"
LZ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAP_DIR="${E2E_EKS_AGENT_PLATFORM_DIR:-$(cd "$LZ_DIR/../eks-agent-platform" 2>/dev/null && pwd || echo /nonexistent)}"
CLOUDGOV_DIR="${E2E_CLOUDGOV_DIR:-$(cd "$LZ_DIR/../cloudgov" 2>/dev/null && pwd || echo /nonexistent)}"
BASE="$LZ_DIR/live/aws/$ACCOUNT_DIR/$REGION/$ENVIRONMENT"
ECR="${E2E_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/eks-agent-platform/operator"
WORK="$(mktemp -d)"
RESULT="FAILED"

log() { echo -e "\n\033[1;36m=== $* ===\033[0m"; }
die() { echo -e "\033[1;31mFATAL: $*\033[0m" >&2; exit 1; }
tg()  { ( cd "$BASE/$1" && TG_NON_INTERACTIVE=true terragrunt "${@:2}" ); }

# Wait until a Deployment exists and is Available.
wait_avail() {
  local ns=$1 dep=$2 to=${3:-300} i
  for ((i = 0; i < to; i += 5)); do
    if kubectl -n "$ns" get deploy "$dep" >/dev/null 2>&1 &&
      kubectl -n "$ns" wait --for=condition=Available "deploy/$dep" --timeout=5s >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# --- teardown (ALWAYS runs) -------------------------------------------------
teardown() {
  local ec=$?
  log "TEARDOWN (script exit $ec) — reaping everything to stop spend"
  # Platform CR first so the operator finalizer removes the tenant IAM role.
  kubectl delete platform "$TENANT" -n eks-agent-platform --wait=true --timeout=180s 2>/dev/null || true
  # Drop the tenant manifest from git so ArgoCD won't recreate it.
  if [ -d "$WORK/tenants/.git" ]; then
    (
      cd "$WORK/tenants" &&
        git rm -f "tenants/$CLUSTER/$TENANT.yaml" >/dev/null 2>&1 &&
        git -c user.name=e2e -c user.email=e2e@local commit -q -m "e2e: remove $TENANT" &&
        git push -q origin HEAD:main
    ) 2>/dev/null || true
  fi
  # Destroy substrate in reverse dependency order. cluster-bootstrap is
  # in-cluster only (no billable AWS) + finalizer-prone, so it dies with the
  # cluster rather than being destroyed on its own.
  for c in agent-iam cluster network; do
    log "destroy $c"
    tg "$c" destroy -auto-approve >/dev/null 2>&1 || echo "  (destroy $c reported an issue — verify in console)"
  done
  log "zero-billable check (us-$REGION)"
  echo "  EKS:  $(aws eks list-clusters --region "$REGION" --query 'clusters' --output text 2>/dev/null | tr '\t' ' ' || echo '?')"
  echo "  NAT:  $(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' ' ' || echo '?')"
  echo "  EIP:  $(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text 2>/dev/null | tr '\t' ' ' || echo '?')"
  # Restore the committed placeholder account.hcl so a local run never leaves the
  # real account ID in a tracked file.
  git -C "$LZ_DIR" checkout -- "live/aws/$ACCOUNT_DIR/account.hcl" 2>/dev/null || true
  rm -rf "$WORK"
  if [ "$RESULT" = PASSED ]; then echo -e "\n\033[1;32mE2E PASSED\033[0m"; else echo -e "\n\033[1;31mE2E FAILED\033[0m"; exit 1; fi
}
trap teardown EXIT

# --- 0. preflight -----------------------------------------------------------
log "PREFLIGHT"
[ -d "$EAP_DIR/charts/operator" ] || die "eks-agent-platform not found at $EAP_DIR (set E2E_EKS_AGENT_PLATFORM_DIR)"
[ -d "$CLOUDGOV_DIR" ] || die "cloudgov not found at $CLOUDGOV_DIR (set E2E_CLOUDGOV_DIR)"
acct=$(aws sts get-caller-identity --query Account --output text)
[ "$acct" = "$E2E_ACCOUNT_ID" ] || die "creds are for $acct, expected $E2E_ACCOUNT_ID"
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 &&
  die "cluster $CLUSTER already exists — refusing to clobber. Tear it down first."
echo "  account $acct OK; region $REGION clean; tenant=$TENANT"

# --- 1. substrate -----------------------------------------------------------
log "ACCOUNT + BACKEND"
printf 'locals {\n  account_id    = "%s"\n  account_alias = "%s"\n}\n' "$E2E_ACCOUNT_ID" "$ACCOUNT_DIR" \
  >"$LZ_DIR/live/aws/$ACCOUNT_DIR/account.hcl"
"$LZ_DIR/scripts/init-backend-aws.sh" "$E2E_ACCOUNT_ID" "$REGION"

log "APPLY network"; tg network apply -auto-approve
log "APPLY cluster (~15-25m)"; tg cluster apply -auto-approve
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
log "APPLY cluster-bootstrap (CoreDNS fix + portal-reader token + ArgoCD tenants cred)"
TF_VAR_tenants_repo_url="$TENANTS_REPO" tg cluster-bootstrap apply -auto-approve
log "APPLY agent-iam"; tg agent-iam apply -auto-approve

# --- 2. operator (self-contained: build arm64 + install) --------------------
# Self-contained so the e2e has no dependency on a published release. Once a
# release is tagged, this whole block can be deleted: the operator installs
# itself via the eks-gitops addons-agent-operator ApplicationSet.
log "OPERATOR image (arm64 -> ECR)"
SHA=$(git -C "$EAP_DIR" rev-parse --short HEAD)
aws ecr describe-repositories --repository-names eks-agent-platform/operator --region "$REGION" >/dev/null 2>&1 ||
  aws ecr create-repository --repository-name eks-agent-platform/operator --region "$REGION" >/dev/null
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR%%/*}" >/dev/null
docker buildx build --platform linux/arm64 --build-arg TARGETARCH=arm64 --build-arg VERSION="$SHA" \
  -t "$ECR:$SHA" --push --no-cache --provenance=false -f "$EAP_DIR/operators/Dockerfile" "$EAP_DIR/operators" >/dev/null

log "WAIT for cert-manager (ArgoCD syncs it after the apply returns)"
wait_avail cert-manager cert-manager-webhook 600 || die "cert-manager-webhook not Available"

log "OPERATOR install"
OIDC_ARN=$(tg cluster output -raw oidc_provider_arn 2>/dev/null)
OIDC_HOST=$(tg cluster output -raw oidc_issuer 2>/dev/null)
ROLE_ARN="arn:aws:iam::${E2E_ACCOUNT_ID}:role/eks-agent-platform/${ENVIRONMENT}-eks-agent-platform-operator"
helm install operator "$EAP_DIR/charts/operator" -n eks-agent-platform --create-namespace \
  --set image.repository="$ECR" --set image.tag="$SHA" \
  --set config.environment="$ENVIRONMENT" --set config.region="$REGION" \
  --set config.oidc.providerArn="$OIDC_ARN" --set config.oidc.issuerHost="$OIDC_HOST" \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ROLE_ARN" \
  --set webhooks.certManager.installSelfSignedIssuer=true --wait --timeout 5m
wait_avail eks-agent-platform operator 120 || die "operator not Available"
echo "  operator Available"

# --- 3. tenant via GitOps (commit to tenants repo -> ArgoCD applies) --------
log "TENANT $TENANT (render charts/tenant -> push -> ArgoCD)"
git clone -q "$TENANTS_REPO" "$WORK/tenants"
mkdir -p "$WORK/tenants/tenants/$CLUSTER"
helm template "$TENANT" "$EAP_DIR/charts/tenant" \
  --set platform.name="$TENANT" --set platform.tenant="$TENANT" --set platform.persona=eng \
  >"$WORK/tenants/tenants/$CLUSTER/$TENANT.yaml"
(
  cd "$WORK/tenants" &&
    git add -A &&
    git -c user.name=e2e -c user.email=e2e@local commit -q -m "e2e: create $TENANT on $CLUSTER" &&
    git push -q origin HEAD:main
)
log "WAIT for the Platform CR (ArgoCD git poll + sync + reconcile)"
for ((i = 0; i < 360; i += 10)); do
  kubectl get platform "$TENANT" -n eks-agent-platform >/dev/null 2>&1 && break
  sleep 10
done
kubectl wait --for=condition=Ready "platform/$TENANT" -n eks-agent-platform --timeout=300s ||
  die "Platform $TENANT did not reach Ready"

# --- 4. validate ------------------------------------------------------------
log "VALIDATE real-IRSA conformance"
ROLE=$(kubectl get platform "$TENANT" -n eks-agent-platform -o jsonpath='{.status.iamRoleArn}')
[ -n "$ROLE" ] || die "Platform has no status.iamRoleArn"
RN="${ROLE##*/}"
[ "$(aws iam list-role-policies --role-name "$RN" --query 'length(PolicyNames)' --output text)" = "0" ] ||
  die "tenant role $RN has inline policies (expected none)"
aws iam get-role --role-name "$RN" --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text | grep -q boundary ||
  die "tenant role $RN missing permissions boundary"
echo "  IRSA role $RN: permissions boundary set, zero inline policies"

log "VALIDATE cloudgov platform audit"
(cd "$CLOUDGOV_DIR" && go build -o "$WORK/cloudgov" .)
"$WORK/cloudgov" platform audit --fail-on HIGH || die "cloudgov reported CRITICAL/HIGH findings"
echo "  cloudgov: no CRITICAL/HIGH findings"

RESULT="PASSED"
log "ALL GATES PASSED — tearing down"
