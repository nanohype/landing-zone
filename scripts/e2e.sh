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
# Claude access in the region, kubectl/helm/terragrunt/tofu/jq/go, the sibling
# eks-agent-platform + cloudgov repos on disk, git auth to push to the tenants
# repo (SSH key locally; a token-credential helper in CI), and the operator
# release published to ghcr (the GitOps install pulls it).
#
set -euo pipefail

# --- config (env-overridable; defaults target the cheap development tree) -----------
: "${E2E_ACCOUNT_ID:?set E2E_ACCOUNT_ID (the real 12-digit AWS account)}"
REGION="${E2E_REGION:-us-west-2}"
ENVIRONMENT="${E2E_ENV:-development}"
ACCOUNT_DIR="${E2E_ACCOUNT_DIR:-workload-development}"
CLUSTER="${E2E_CLUSTER:-development-platform}"
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
WORK="$(mktemp -d)"
RESULT="FAILED"

log() { echo -e "\n\033[1;36m=== $* ===\033[0m"; }
die() { echo -e "\033[1;31mFATAL: $*\033[0m" >&2; exit 1; }
tg()  { ( cd "$BASE/$1" && TG_NON_INTERACTIVE=true terragrunt "${@:2}" ); }

# Clear a stale Terragrunt/S3 state lock for a component. An interrupted run
# (Ctrl-C, killed mid-apply) leaves a .tflock that blocks the next apply/destroy.
# Key mirrors root.hcl: <env>/<path_relative_to_include>/terraform.tfstate.tflock.
clear_lock() {
  aws s3api delete-object --bucket "${E2E_ACCOUNT_ID}-${REGION}-tfstate" \
    --key "${ENVIRONMENT}/aws/${ACCOUNT_DIR}/${REGION}/${ENVIRONMENT}/$1/terraform.tfstate.tflock" \
    2>/dev/null && echo "  cleared stale state lock for $1" || true
}

# Reap cluster-owned AWS resources Terraform doesn't track — they linger as cost
# or collide with a re-apply. All scoped STRICTLY to THIS cluster's tag/name.
reap_cluster_orphans() {
  # EKS control-plane log group (collides with a fresh apply; not billable).
  aws logs delete-log-group --log-group-name "/aws/eks/$CLUSTER/cluster" --region "$REGION" 2>/dev/null || true
  # CSI-provisioned EBS volumes + their snapshots (loki/tempo/prometheus addons).
  for v in $(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" Name=status,Values=available --query 'Volumes[].VolumeId' --output text 2>/dev/null); do
    aws ec2 delete-volume --region "$REGION" --volume-id "$v" 2>/dev/null && echo "  reaped EBS volume $v" || true
  done
  for s in $(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Snapshots[].SnapshotId' --output text 2>/dev/null); do
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$s" 2>/dev/null && echo "  reaped EBS snapshot $s" || true
  done
  # Cluster KMS secrets-encryption key — lingers ENABLED (~$1/mo) after destroy;
  # schedule it for deletion (7-day minimum window) + drop the alias.
  local kid
  kid=$(aws kms describe-key --region "$REGION" --key-id "alias/eks/$CLUSTER" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || true)
  if [ -n "$kid" ] && [ "$kid" != "None" ]; then
    aws kms schedule-key-deletion --region "$REGION" --key-id "$kid" --pending-window-in-days 7 2>/dev/null && echo "  scheduled KMS key $kid for deletion" || true
    aws kms delete-alias --region "$REGION" --alias-name "alias/eks/$CLUSTER" 2>/dev/null || true
  fi
  # Tenant IRSA role the operator minted at runtime (finalizer fallback if the
  # in-cluster delete raced selfHeal or the operator was already gone).
  local trole="$ENVIRONMENT-$TENANT-tenant" p ip
  if aws iam get-role --role-name "$trole" >/dev/null 2>&1; then
    for p in $(aws iam list-attached-role-policies --role-name "$trole" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$trole" --policy-arn "$p" 2>/dev/null || true
    done
    for ip in $(aws iam list-role-policies --role-name "$trole" --query 'PolicyNames' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$trole" --policy-name "$ip" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$trole" 2>/dev/null && echo "  reaped tenant role $trole (finalizer fallback)" || true
  fi
}

# Orphaned EKS security groups + available ENIs (created by the cluster, outside
# Terraform state) block the VPC destroy. Revoke SG rules to break cross-refs,
# then delete. Scoped to THIS cluster's tag.
reap_vpc_blockers() {
  local eni sg ing egr
  for eni in $(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" Name=status,Values=available --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null && echo "  reaped ENI $eni" || true
  done
  for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    ing=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
    [ -n "$ing" ] && [ "$ing" != "[]" ] && aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$sg" --ip-permissions "$ing" >/dev/null 2>&1 || true
    egr=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
    [ -n "$egr" ] && [ "$egr" != "[]" ] && aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$sg" --ip-permissions "$egr" >/dev/null 2>&1 || true
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null && echo "  reaped security group $sg" || true
  done
}

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

# Dump the tenant pipeline state when the Platform never reaches Ready — pins the
# cause (ArgoCD didn't apply the commit vs the operator didn't reconcile) before
# teardown destroys the evidence.
dump_diag() {
  echo "::group::DIAGNOSTICS (Platform not Ready)"
  echo "--- platforms (all namespaces) ---"; kubectl get platform -A 2>&1 | tail -20
  echo "--- describe platform/$TENANT ---"; kubectl describe platform "$TENANT" -n eks-agent-platform 2>&1 | tail -45
  echo "--- argocd applications ---"; kubectl get applications -n argocd 2>&1 | tail -25
  echo "--- describe application/portal-tenants-$CLUSTER ---"; kubectl describe application "portal-tenants-$CLUSTER" -n argocd 2>&1 | tail -50
  echo "--- argocd repo credential present? ---"; kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o custom-columns=NAME:.metadata.name,TYPE:.type 2>&1
  echo "--- applicationset/portal-tenants status ---"; kubectl describe applicationset portal-tenants -n argocd 2>&1 | tail -30
  echo "--- operator logs ---"; kubectl logs -n eks-agent-platform deploy/eks-agent-platform-operator --tail=50 2>&1
  echo "::endgroup::"
}

# Dump the GitOps operator-install chain when the Deployment never goes Available:
# in-cluster secret (the AppSet generator inputs) -> addons-agent-operator AppSet
# -> eks-agent-platform-operator Application -> Deployment/pods -> webhook cert.
dump_operator_diag() {
  echo "::group::DIAGNOSTICS (operator GitOps install)"
  echo "--- in-cluster secret labels + annotations (AppSet generator inputs) ---"
  kubectl -n argocd get secret in-cluster -o jsonpath='labels={.metadata.labels}{"\n"}annotations={.metadata.annotations}{"\n"}' 2>&1
  echo ""; echo "--- argocd applications ---"; kubectl -n argocd get applications 2>&1 | tail -30
  echo "--- describe application/eks-agent-platform-operator ---"; kubectl -n argocd describe application eks-agent-platform-operator 2>&1 | tail -55
  echo "--- applicationset/addons-agent-operator status ---"; kubectl -n argocd describe applicationset addons-agent-operator 2>&1 | grep -A20 -iE "conditions|events" | tail -25
  echo "--- eks-agent-platform ns (deploy/pods/cert) + clusterissuers ---"; kubectl -n eks-agent-platform get deploy,pods,certificate 2>&1; kubectl get clusterissuer 2>&1 | tail -5
  echo "--- pod events ---"; kubectl -n eks-agent-platform describe pods 2>&1 | grep -A25 "Events:" | tail -30
  echo "--- operator logs ---"; kubectl -n eks-agent-platform logs deploy/eks-agent-platform-operator --tail=40 2>&1 | tail -40
  echo "::endgroup::"
}

# --- teardown (ALWAYS runs) -------------------------------------------------
teardown() {
  local ec=$?
  log "TEARDOWN (script exit $ec) — reaping everything to stop spend"
  # Drop the tenant from git FIRST so ArgoCD (selfHeal) can't recreate the
  # Platform CR mid-delete, then delete the ArgoCD app so it stops managing it.
  if [ -d "$WORK/tenants/.git" ]; then
    (
      cd "$WORK/tenants" &&
        git rm -f "tenants/$CLUSTER/$TENANT.yaml" >/dev/null 2>&1 &&
        git -c user.name=e2e -c user.email=e2e@local commit -q -m "e2e: remove $TENANT" &&
        git push -q origin HEAD:main
    ) 2>/dev/null || true
  fi
  kubectl -n argocd delete application "portal-tenants-$CLUSTER" --cascade=foreground --timeout=120s 2>/dev/null || true
  # Now delete the Platform CR; the operator finalizer reaps the tenant IRSA role
  # while the operator is still running (before the cluster is destroyed below).
  kubectl delete platform "$TENANT" -n eks-agent-platform --wait=true --timeout=180s 2>/dev/null || true
  # Destroy substrate in reverse dependency order (agent-iam depends on secrets;
  # both depend on cluster). cluster-bootstrap is in-cluster only (no billable AWS)
  # + finalizer-prone, so it dies with the cluster.
  for c in agent-iam secrets cluster network; do
    log "destroy $c"
    if ! tg "$c" destroy -auto-approve >/dev/null 2>&1; then
      # Usual causes: a stale state lock (interrupted run) or orphaned EKS SGs/ENIs
      # blocking the VPC. Clear both and retry once.
      echo "  destroy $c failed — clearing lock + VPC blockers, retrying"
      clear_lock "$c"
      [ "$c" = network ] && reap_vpc_blockers
      tg "$c" destroy -auto-approve >/dev/null 2>&1 || echo "  (destroy $c still failing — verify in console)"
    fi
  done
  reap_cluster_orphans

  # Assert zero-billable: a failed/partial destroy must FAIL LOUDLY, not just
  # report (a mid-teardown network drop once left a cluster up silently). Every
  # check is scoped to THIS run's tag/name so it never flags other infra.
  log "zero-billable check (us-$REGION)"
  local eks nat eip vpc ebs leak="" r
  eks=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.name' --output text 2>/dev/null || true)
  nat=$(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' ' ')
  eip=$(aws ec2 describe-addresses --region "$REGION" --filters Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" --query 'Addresses[].PublicIp' --output text 2>/dev/null | tr '\t' ' ')
  vpc=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' ' ')
  ebs=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' ' ')
  echo "  EKS: ${eks:-clean}"; echo "  NAT: ${nat:-clean}"; echo "  EIP: ${eip:-clean}"; echo "  VPC: ${vpc:-clean}"; echo "  EBS: ${ebs:-clean}"
  for r in "$eks" "$nat" "$eip" "$vpc" "$ebs"; do if [ -n "$r" ] && [ "$r" != "None" ]; then leak=1; fi; done
  rm -rf "$WORK"
  if [ -n "$leak" ]; then
    echo -e "\n\033[1;31m!!! BILLABLE RESOURCES REMAIN — MANUAL CLEANUP REQUIRED (see above) !!!\033[0m" >&2
    echo "    Re-run 'task e2e' (teardown is idempotent) or clear them in the console." >&2
    RESULT="FAILED"
  fi
  # account.hcl is never written now (the real id is injected via TERRAGRUNT_ACCOUNT_ID),
  # so there is nothing to restore.
  if [ "$RESULT" = PASSED ]; then echo -e "\n\033[1;32mE2E PASSED\033[0m"; else echo -e "\n\033[1;31mE2E FAILED\033[0m"; exit 1; fi
}
trap teardown EXIT

# --- 0. preflight -----------------------------------------------------------
log "PREFLIGHT"
[ -d "$EAP_DIR/charts/tenant" ] || die "eks-agent-platform not found at $EAP_DIR (set E2E_EKS_AGENT_PLATFORM_DIR)"
[ -d "$CLOUDGOV_DIR" ] || die "cloudgov not found at $CLOUDGOV_DIR (set E2E_CLOUDGOV_DIR)"
acct=$(aws sts get-caller-identity --query Account --output text)
[ "$acct" = "$E2E_ACCOUNT_ID" ] || die "creds are for $acct, expected $E2E_ACCOUNT_ID"
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 &&
  die "cluster $CLUSTER already exists — refusing to clobber. Tear it down first."
# Reap any orphaned EKS control-plane log group left by a prior run's teardown
# (EKS leaves /aws/eks/<cluster>/cluster on destroy; a fresh apply fails creating
# it with "already exists"). Idempotent — a no-op when there's nothing to reap.
aws logs delete-log-group --log-group-name "/aws/eks/$CLUSTER/cluster" --region "$REGION" 2>/dev/null &&
  echo "  reaped orphaned log group /aws/eks/$CLUSTER/cluster" || true
# Clear any stale state locks from a prior interrupted run so this apply isn't
# blocked waiting on a lock that will never release on its own.
for c in network cluster secrets cluster-bootstrap agent-iam; do clear_lock "$c"; done
echo "  account $acct OK; region $REGION clean; tenant=$TENANT"

# --- 1. substrate -----------------------------------------------------------
log "ACCOUNT + BACKEND"
# Inject the real account id via env (root.hcl reads TERRAGRUNT_ACCOUNT_ID) rather
# than writing it into the tracked account.hcl placeholder — no real id ever lands
# in a tracked file, and there is no restore-on-teardown that could fail and leak it.
export TERRAGRUNT_ACCOUNT_ID="$E2E_ACCOUNT_ID"
"$LZ_DIR/scripts/init-backend-aws.sh" "$E2E_ACCOUNT_ID" "$REGION"

log "APPLY network"; tg network apply -auto-approve
log "APPLY cluster (~15-25m)"; tg cluster apply -auto-approve
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
log "APPLY cluster-bootstrap (CoreDNS fix + portal-reader token + ArgoCD tenants cred)"
# enable_agent_platform=true: the eks-gitops addons-agent-operator ApplicationSet
# installs the operator from the published release (ghcr operator:<chart appVersion>),
# wired with this cluster's OIDC provider + operator role via the in-cluster ArgoCD
# secret annotations cluster-bootstrap sets. This is the production install path.
TF_VAR_tenants_repo_url="$TENANTS_REPO" TF_VAR_enable_agent_platform=true \
  tg cluster-bootstrap apply -auto-approve
# secrets provisions the data CMK that agent-iam encrypts its model-artifacts +
# eval-reports buckets with (dependency.secrets.outputs.kms_key_arn). It MUST apply
# before agent-iam — the dependency's mock is restricted to validate/plan, so a
# missing secrets state fails the agent-iam apply loudly instead of baking the mock
# KMS ARN into real SSE-KMS + IAM config.
log "APPLY secrets"; tg secrets apply -auto-approve
log "APPLY agent-iam"; tg agent-iam apply -auto-approve

# --- 2. operator (GitOps: ArgoCD installs the released image) ----------------
log "WAIT for cert-manager (the operator webhook cert depends on it)"
wait_avail cert-manager cert-manager-webhook 600 || die "cert-manager-webhook not Available"
log "OPERATOR (GitOps via addons-agent-operator ApplicationSet)"
# The install chain is long: cluster-bootstrap sets eks-agent-platform/enabled ->
# the AppSet generator creates the eks-agent-platform-operator Application -> ArgoCD
# syncs the chart (pulling public ghcr operator:<release>) -> cert-manager issues the
# webhook cert -> the pod goes Ready. Nudge the AppSet controller to discover the
# label now (not on its ~3m poll), hard-refresh the Application each loop, and wait.
kubectl -n argocd rollout restart deployment/argocd-applicationset-controller >/dev/null 2>&1 || true
opok=""
for ((i = 0; i < 600; i += 10)); do
  if kubectl -n eks-agent-platform get deploy eks-agent-platform-operator >/dev/null 2>&1 &&
    kubectl -n eks-agent-platform wait --for=condition=Available deploy/eks-agent-platform-operator --timeout=5s >/dev/null 2>&1; then
    opok=1
    break
  fi
  kubectl -n argocd annotate application eks-agent-platform-operator argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  [ $((i % 60)) -eq 0 ] && echo "  ...${i}s: operator Deployment not Available yet"
  sleep 10
done
[ -n "$opok" ] || { dump_operator_diag; die "operator Deployment not Available (GitOps install)"; }
echo "  operator Available (GitOps-installed from the released image)"

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
log "WAIT for the Platform CR (ArgoCD git poll + sync + operator reconcile)"
# Nudge ArgoCD to act on the just-pushed commit now instead of on its ~3m
# generator/sync poll: bounce the ApplicationSet controller so its git generator
# re-runs immediately (discovers tenants/$CLUSTER), and hard-refresh the tenant
# Application each loop once the AppSet has generated it (forces an immediate
# sync). Best-effort — a name mismatch or not-yet-created app is a no-op.
kubectl -n argocd rollout restart deployment/argocd-applicationset-controller >/dev/null 2>&1 || true
APP="portal-tenants-$CLUSTER"
# The operator signals tenant readiness via .status.phase=Ready — its conditions
# are granular (NamespaceReady, Suspended), with no aggregate Ready condition —
# so poll the phase rather than `kubectl wait --for=condition=Ready`.
phase=""
for ((i = 0; i < 720; i += 10)); do
  phase=$(kubectl get platform "$TENANT" -n eks-agent-platform -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Ready" ] && break
  kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  [ $((i % 60)) -eq 0 ] && echo "  ...${i}s: Platform phase='${phase:-<absent>}'"
  sleep 10
done
[ "$phase" = "Ready" ] || { dump_diag; die "Platform $TENANT did not reach phase=Ready (last: '${phase:-<absent>}')"; }
echo "  Platform $TENANT phase=Ready"

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
