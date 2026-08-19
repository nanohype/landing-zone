#!/usr/bin/env bash
#
# Manual end-to-end validation of the nanohype stack on a REAL AWS account:
# provision the substrate, install the operator, deploy one tenant through
# GitOps, assert tenant-role conformance + cloudgov, then tear everything down.
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
REGION="${E2E_REGION:-us-east-1}"
ENVIRONMENT="${E2E_ENV:-development}"
ACCOUNT_DIR="${E2E_ACCOUNT_DIR:-workload-development}"
CLUSTER="${E2E_CLUSTER:-development-platform}"
TENANT="${E2E_TENANT:-e2e-smoke}"
TENANTS_REPO="${E2E_TENANTS_REPO:-git@github.com:nanohype/tenants.git}"
# The tenant map tenant-substrate reads. Tracked, and rewritten for the duration
# of this run — see the preflight refusal and the teardown restore.
TENANTS_MAP_REL="live/aws/$ACCOUNT_DIR/$REGION/$ENVIRONMENT/tenant-substrate/tenants.generated.json"
# Only when AWS_PROFILE is UNSET (local runs), fall back to the documented
# workload-<env> SSO profile name — which is what ACCOUNT_DIR already holds. In CI
# it's set empty so the OIDC env credentials are used instead of a named profile.
AWS_PROFILE="${AWS_PROFILE-$ACCOUNT_DIR}"
if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else unset AWS_PROFILE; fi
export AWS_REGION="$REGION"
LZ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EAP_DIR="${E2E_EKS_AGENT_PLATFORM_DIR:-$(cd "$LZ_DIR/../eks-agent-platform" 2>/dev/null && pwd || echo /nonexistent)}"
CLOUDGOV_DIR="${E2E_CLOUDGOV_DIR:-$(cd "$LZ_DIR/../cloudgov" 2>/dev/null && pwd || echo /nonexistent)}"
BASE="$LZ_DIR/live/aws/$ACCOUNT_DIR/$REGION/$ENVIRONMENT"
WORK="$(mktemp -d)"
TENANTS_MAP="$LZ_DIR/$TENANTS_MAP_REL"
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
  # Second pass over the operator-minted roles, for anything the destroys
  # themselves surfaced. The pass that matters for agent-iam runs earlier — see
  # reap_operator_roles.
  reap_operator_roles
}

# Roles the operator minted at runtime, for EVERY Platform on this cluster.
#
# Called TWICE, and both calls matter.
#
# Before the destroy loop, because agent-iam is IN that loop: the tenant-baseline
# managed policy cannot be deleted while any role still has it attached, so one
# surviving role fails that destroy and everything below it in the reverse order
# stays standing. A sweep that only runs afterwards reaps the blocker after the
# destroy it would have unblocked has already failed. It also catches roles left
# by an EARLIER run, whose Platform CRs no longer exist for a finalizer to act on.
#
# And after, for anything the destroys themselves surfaced.
#
# Enumerated from IAM rather than reconstructed from a name. The operator names
# them <cluster>-<platform>-{tenant,session} under /eks-agent-platform/, so
# listing that path and filtering on this cluster's prefix finds all of them,
# including kinds this script does not name. A constructed name was wrong twice
# over: it built <environment>-<tenant>-tenant against an operator that writes
# <cluster>-<platform>-tenant, so it had never matched anything — and a fallback
# that silently matches nothing is indistinguishable from one with nothing to do.
#
# This is the fallback, not the mechanism. Deleting the Platform CR while the
# operator still runs is what reaps a tenant identity properly, because the
# operator also removes the Pod Identity association and the scoped policies it
# generated. This exists for when the operator is already gone.
#
# The operator's own role is excluded: agent-iam created it and terraform
# destroys it, so reaping it here would only race that.
reap_operator_roles() {
  local operator_role="$CLUSTER-agent-platform-operator" r p ip
  for r in $(aws iam list-roles --path-prefix /eks-agent-platform/ \
    --query "Roles[?starts_with(RoleName, '$CLUSTER-')].RoleName" --output text 2>/dev/null); do
    [ "$r" = "$operator_role" ] && continue
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$p" 2>/dev/null || true
    done
    for ip in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$r" --policy-name "$ip" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$r" 2>/dev/null && echo "  reaped operator-minted role $r" || true
  done
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
#
# Bounded on wall clock, not an iteration count. `kubectl wait` burns up to its
# own --timeout before the sleep, so counting iterations bounds at roughly DOUBLE
# the stated seconds whenever the Deployment exists but is not Available, and
# stays honest when it does not exist, because the `get` fails fast. The error is
# therefore not a constant offset: the timeout stretches furthest in the
# half-working case, which is the one a bounded wait is for.
wait_avail() {
  local ns=$1 dep=$2 to=${3:-300} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$to" ]; do
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

# Capture why the cluster is unhappy, BEFORE the teardown deletes the evidence.
#
# There is a dump_operator_diag for the operator phase and nothing for the phases
# before it, so a failure in the cluster apply destroys the only thing that could
# explain it. That is what happened to the aws-ebs-csi-driver addon timing out at
# 20m in CREATING: by the time anyone could look, the control plane was already
# being deleted and the three questions that would separate a Pod Identity race
# from a scheduling problem — node conditions, which pods are not Running, and
# what the events say — were unanswerable.
#
# Everything here is best-effort and time-boxed. Diagnostics must never be able to
# delay a teardown that exists to stop spend, so every call carries a timeout and
# a `|| true`, and the whole thing returns 0 if the cluster is already gone.
dump_cluster_diag() {
  aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || return 0
  log "CLUSTER DIAGNOSTICS (captured before teardown)"
  local a
  for a in $(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --query 'addons' --output text 2>/dev/null); do
    echo "  addon $a:"
    aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --region "$REGION" \
      --query 'addon.{status:status,health:health.issues}' --output json 2>/dev/null | sed 's/^/    /'
  done
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || return 0
  # Probe once before asking three questions. A private-endpoint cluster answers
  # the AWS control-plane calls above and none of the kubectl ones, and each
  # failure prints five identical resolver errors — fifteen lines of noise shaped
  # like data, which is the defect this function exists to catch. Say what is
  # wrong instead, and say it once.
  if ! kubectl version -o json --request-timeout=15s >/dev/null 2>&1; then
    echo "  kubectl: cannot reach the API endpoint from here."
    echo "    endpointPublicAccess=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
      --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>/dev/null)," \
      "publicAccessCidrs=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
      --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null)"
    echo "    Node, pod and event state are unavailable — they need in-cluster reach."
    return 0
  fi
  echo "  nodes:"; kubectl get nodes -o wide --request-timeout=20s 2>&1 | sed 's/^/    /' | head -12
  # NOT `--field-selector=status.phase!=Running`. A CrashLoopBackOff pod is phase
  # Running, so that selector cannot see the single state this function most needs
  # to report — it printed "No resources found" on a cluster where both
  # ebs-csi-controller replicas had all six containers restarting, and only the
  # event stream gave it away. Select on container readiness and restarts instead,
  # which is what "unhealthy" actually means here.
  echo "  pods unhealthy (not-ready containers or restarts):"
  kubectl get pods -A --no-headers --request-timeout=20s 2>/dev/null |
    awk '{split($3,r,"/"); if ($4 != "Running" || r[1] != r[2] || $5+0 > 0) print}' |
    sed 's/^/    /' | head -25
  # The logs are the point. Everything above says a container is failing; only this
  # says why. --previous reads the crashed instance rather than the one currently
  # starting, which is the copy that holds the error.
  echo "  logs from restarting containers:"
  kubectl get pods -A --no-headers --request-timeout=20s 2>/dev/null |
    awk '$5+0 > 0 {print $1, $2}' | head -4 |
    while read -r ns pod; do
      for c in $(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.containerStatuses[?(@.restartCount>0)].name}' --request-timeout=15s 2>/dev/null); do
        echo "    --- $ns/$pod [$c] ---"
        kubectl logs "$pod" -n "$ns" -c "$c" --previous --tail=15 --request-timeout=20s 2>&1 | sed 's/^/      /'
      done
    done
  echo "  recent events:"; kubectl get events -A --sort-by=.lastTimestamp --request-timeout=20s 2>&1 | tail -25 | sed 's/^/    /'
}

# --- teardown (ALWAYS runs) -------------------------------------------------
teardown() {
  local ec=$?
  # Before anything is deleted, and only when the run is failing — a passing run
  # has nothing to explain and the extra API calls would just slow the reap.
  [ "$ec" -ne 0 ] && dump_cluster_diag || true
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
  # Stop every Application's automated sync before deleting the CRs they manage.
  # selfHeal would otherwise recreate a Platform mid-delete, and the operator's
  # finalizer never completes against a CR that keeps coming back. Clearing
  # syncPolicy disables the automation without deleting anything ArgoCD manages,
  # which a cascading delete of the Applications would.
  kubectl -n argocd patch applications --all --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
  # Delete EVERY Platform, not just this run's.
  #
  # The operator reaps a tenant's AWS identity from a finalizer, so that only
  # happens for a CR deleted while the operator is still running — which is here,
  # before the cluster goes. This used to name "$TENANT" alone, and the gitops
  # catalog deploys Platforms of its own: an `ops` Platform arrives with the addon
  # catalog, no e2e ever created it, and nothing deleted it. Its tenant and
  # session roles therefore outlived the cluster, and because the tenant-baseline
  # managed policy cannot be deleted while a role still has it attached, they
  # failed the agent-iam destroy.
  #
  # Deleting the CRs is the mechanism; the IAM sweep in reap_cluster_orphans is
  # the fallback for when the operator is already gone. The sweep alone cannot
  # cover this, because it runs after the destroy loop that agent-iam is in.
  kubectl delete platform --all -A --wait=true --timeout=300s 2>/dev/null || true
  # Whatever the finalizers did not cover — including roles from an earlier run,
  # whose Platform CRs are long gone — must go before agent-iam is destroyed.
  reap_operator_roles
  # Destroy substrate in reverse dependency order (agent-iam depends on secrets;
  # both depend on cluster). cluster-bootstrap is in-cluster only (no billable AWS)
  # + finalizer-prone, so it dies with the cluster.
  local destroy_failed=""
  # tenant-substrate first: it depends on cluster + secrets, so destroying it
  # after them strands its resources behind a deleted VPC and a deleted CMK.
  # cluster-bootstrap before cluster: its resources live INSIDE the cluster, so
  # the kubernetes provider needs the apiserver still reachable. It also mints a
  # github_repository_deploy_key on the tenants repo — the one thing it creates
  # that destroying the cluster does not remove, so skipping its destroy leaves a
  # credential on a private repo behind on every run.
  for c in tenant-substrate cluster-bootstrap agent-iam secrets cluster network; do
    log "destroy $c"
    if ! tg "$c" destroy -auto-approve >/dev/null 2>&1; then
      # Usual causes: a stale state lock (interrupted run) or orphaned EKS SGs/ENIs
      # blocking the VPC. Clear both and retry once.
      echo "  destroy $c failed — clearing lock + VPC blockers, retrying"
      clear_lock "$c"
      [ "$c" = network ] && reap_vpc_blockers
      if ! tg "$c" destroy -auto-approve >/dev/null 2>&1; then
        # A destroy that fails twice is a run result, not a note. It used to be
        # echoed and swallowed, so a BucketNotEmpty on agent-iam printed one soft
        # line and the run still reported PASSED.
        echo "  (destroy $c still failing — verify in console)"
        destroy_failed="${destroy_failed}${destroy_failed:+ }$c"
      fi
    fi
  done
  reap_cluster_orphans

  # Assert zero-billable: a failed/partial destroy must FAIL LOUDLY, not just
  # report (a mid-teardown network drop once left a cluster up silently). Every
  # check is scoped to THIS run's tag/name so it never flags other infra.
  #
  # S3 is in the set because the buckets are what a teardown actually wedges on:
  # agent-iam's three and cluster-addons' four all derive from the same
  # <cluster>-<account>-<region>- prefix, and a versioned or still-populated one
  # fails BucketNotEmpty. Leaving S3 out meant the one resource class that halts
  # the reverse teardown was the one class the assertion could not see.
  log "zero-billable check ($REGION)"
  local eks nat eip vpc ebs s3 ddb rds cache msk sqs leak="" r
  eks=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.name' --output text 2>/dev/null || true)
  nat=$(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' ' ')
  eip=$(aws ec2 describe-addresses --region "$REGION" --filters Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" --query 'Addresses[].PublicIp' --output text 2>/dev/null | tr '\t' ' ')
  vpc=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=tag:Project,Values=landing-zone "Name=tag:Environment,Values=$ENVIRONMENT" Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' ' ')
  ebs=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' ' ')
  s3=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${CLUSTER}-${E2E_ACCOUNT_ID}-${REGION}-')].Name" --output text 2>/dev/null | tr '\t' ' ')
  # The datastore kinds tenant-substrate provisions. Every one of these is
  # billable and none was visible to this check before the run applied the
  # component that creates them. Scoped by the <env>-<tenant>- name prefix the
  # module composes, so a foreign estate in the same account is never flagged.
  local pfx="${ENVIRONMENT}-${TENANT}-"
  ddb=$(aws dynamodb list-tables --region "$REGION" --query "TableNames[?starts_with(@, '${pfx}')]" --output text 2>/dev/null | tr '\t' ' ')
  rds=$(aws rds describe-db-clusters --region "$REGION" --query "DBClusters[?starts_with(DBClusterIdentifier, '${pfx}')].DBClusterIdentifier" --output text 2>/dev/null | tr '\t' ' ')
  cache=$(aws elasticache describe-replication-groups --region "$REGION" --query "ReplicationGroups[?starts_with(ReplicationGroupId, '${pfx}')].ReplicationGroupId" --output text 2>/dev/null | tr '\t' ' ')
  msk=$(aws kafka list-clusters-v2 --region "$REGION" --query "ClusterInfoList[?starts_with(ClusterName, '${pfx}')].ClusterName" --output text 2>/dev/null | tr '\t' ' ')
  sqs=$(aws sqs list-queues --region "$REGION" --queue-name-prefix "$pfx" --query 'QueueUrls' --output text 2>/dev/null | tr '\t' ' ')
  echo "  EKS: ${eks:-clean}"; echo "  NAT: ${nat:-clean}"; echo "  EIP: ${eip:-clean}"; echo "  VPC: ${vpc:-clean}"; echo "  EBS: ${ebs:-clean}"; echo "  S3:  ${s3:-clean}"
  echo "  DDB: ${ddb:-clean}"; echo "  RDS: ${rds:-clean}"; echo "  CACHE: ${cache:-clean}"; echo "  MSK: ${msk:-clean}"; echo "  SQS: ${sqs:-clean}"
  for r in "$eks" "$nat" "$eip" "$vpc" "$ebs" "$s3" "$ddb" "$rds" "$cache" "$msk" "$sqs"; do if [ -n "$r" ] && [ "$r" != "None" ]; then leak=1; fi; done
  # Put the committed tenant map back. The preflight refused to start if it
  # carried uncommitted work, so this cannot discard anything.
  if [ -n "${TENANTS_MAP_REL:-}" ]; then
    git -C "$LZ_DIR" checkout -- "$TENANTS_MAP_REL" 2>/dev/null || true
    if ! git -C "$LZ_DIR" diff --quiet -- "$TENANTS_MAP_REL" 2>/dev/null; then
      echo -e "\n\033[1;31m!!! $TENANTS_MAP_REL NOT RESTORED — restore it by hand !!!\033[0m" >&2
      RESULT="FAILED"
    fi
  fi
  rm -rf "$WORK"
  if [ -n "$destroy_failed" ]; then
    echo -e "\n\033[1;31m!!! DESTROY FAILED after retry: $destroy_failed !!!\033[0m" >&2
    echo "    A component that will not destroy leaves everything below it in the" >&2
    echo "    reverse order standing." >&2
    # Defer to the assertion rather than to the exit code. A destroy also fails
    # when it cannot init a root that never applied — nothing to delete, and the
    # error says nothing about what is running. The check above queries AWS
    # directly and is the only one of the two that examined the account, so say
    # which of the two situations this is instead of asserting the worse one.
    if [ -n "$leak" ]; then
      echo "    The zero-billable check DID find resources — see it above." >&2
    else
      echo "    The zero-billable check above found none, so nothing is running." >&2
      echo "    Still a failure: a destroy that errors cannot be read as a destroy" >&2
      echo "    that had nothing to do. Find out which before re-running." >&2
    fi
    RESULT="FAILED"
  fi
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
for c in network cluster secrets cluster-bootstrap agent-iam tenant-substrate; do clear_lock "$c"; done

# Drop the untracked provider locks and source caches under this environment, so
# the run's provider versions come from the repository rather than from whatever
# this machine happens to be carrying.
#
# The lock is the one that bites. .gitignore tracks .terraform.lock.hcl only
# under components/ and fleet/; the per-leaf copies under live/ are local state.
# Terragrunt syncs the LEAF lock into its working directory, so the leaf lock is
# what governs and the tracked component lock never applies. Twelve of the
# sixteen leaves here sat at hashicorp/aws 6.44.0 while
# components/aws/cluster/.terraform.lock.hcl said 6.54.0, and the run died on
# `locked provider ... 6.44.0 does not match constraint >= 6.52.0` — a constraint
# the karpenter module raised after those leaf locks were last written. Nothing
# in the repository was wrong.
#
# That makes it invisible to CI by construction: a fresh runner has no leaf lock,
# tofu resolves against the constraints, every gate passes. Only a machine that
# has run this before can fail, which is the reverse of the usual direction and
# the reason a preflight already reaping orphaned log groups and stale .tflock
# files still let it through — these are the same kind of leftover and simply
# were not on the list.
#
# It also disables the teardown, which is the part that matters. Every `destroy`
# begins with an init, so the fault that stops the apply also stops the EXIT trap
# from cleaning up after it: the safety net sharing a single point of failure
# with the thing it catches. Clearing in preflight covers both, since teardown
# runs later in the same process.
#
# Deleting them is safe and is the point — they are gitignored, tofu regenerates
# them on init, and the regenerated one is pinned by the constraints in source.
find "$BASE" -name '.terraform.lock.hcl' -delete 2>/dev/null || true
find "$BASE" -type d -name '.terragrunt-cache' -prune -exec rm -rf {} + 2>/dev/null || true
echo "  cleared untracked provider locks + terragrunt caches under $ENVIRONMENT"
echo "  account $acct OK; region $REGION clean; tenant=$TENANT"

# --- 1. substrate -----------------------------------------------------------
log "ACCOUNT + BACKEND"
# Inject the real account id via env (root.hcl reads TERRAGRUNT_ACCOUNT_ID) rather
# than writing it into the tracked account.hcl placeholder — no real id ever lands
# in a tracked file, and there is no restore-on-teardown that could fail and leak it.
export TERRAGRUNT_ACCOUNT_ID="$E2E_ACCOUNT_ID"
"$LZ_DIR/scripts/init-backend-aws.sh" "$E2E_ACCOUNT_ID" "$REGION"

# tenant-substrate reads its tenant map from a TRACKED file in this leaf, and
# this run replaces it with a one-tenant map of its own before applying. Refuse
# if that file already carries uncommitted work: the teardown restores it with
# `git checkout`, which would silently discard whatever was there. The refusal is
# what makes the restore safe, rather than the restore being careful.
if ! git -C "$LZ_DIR" diff --quiet -- "$TENANTS_MAP_REL" 2>/dev/null; then
  die "$TENANTS_MAP_REL has uncommitted changes — refusing to overwrite and restore it"
fi

# This run drives the cluster with kubectl from wherever it is invoked — 31 calls
# after `aws eks update-kubeconfig`, waiting on cert-manager, the operator and the
# Platform CR. None of them can work against the cluster this tree builds by
# default: cluster_endpoint_public_access is false, and docs/inputs.md records why
# the committed tree sets no posture — rackctl supplies it at apply time.
#
# This script is not rackctl. It supplied nothing, so every run built a
# private-endpoint cluster and then failed to resolve its API from outside the
# VPC. Observed directly: describe-cluster and list-addons answered while kubectl
# returned `no such host` for the endpoint in the same second.
#
# So supply the same posture rackctl does, scoped to this runner alone. Public
# access with an allow-list of exactly one address is narrower than the private
# default is convenient — the cluster is reachable by this machine for the ~40
# minutes it exists and by nothing else.
#
# Refuse rather than widen. The component already fails closed at plan time on an
# empty CIDR list and offers no 0.0.0.0/0 fallback; a run that cannot establish
# its own address must not be the thing that opens an API endpoint to the world.
RUNNER_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
case "$RUNNER_IP" in
  *[!0-9.]* | "") die "could not determine this runner's public IP — refusing to open the cluster API without a scope" ;;
esac
export TF_VAR_cluster_endpoint_public_access=true
export TF_VAR_cluster_endpoint_public_access_cidrs="[\"${RUNNER_IP}/32\"]"
echo "  cluster API will be reachable from ${RUNNER_IP}/32 only"

# cluster-bootstrap requires gitops_repo_url and deliberately gives it no
# default: without one a cluster would sync its app-of-apps from whatever
# repository happened to be configured, so the component fails the plan instead
# of guessing. Correct, and it means every caller must supply it. rackctl does.
# This script did not, so the run died at `APPLY cluster-bootstrap` with
# `No value for required variable` the first time it ever got that far.
#
# A sweep of all six roots this run applies — every variable that is required,
# has no default, and receives no value from _envcommon, the leaf or root.hcl —
# returns this one and nothing else. That is a statement about this class only:
# a variable with a default that is wrong here, or one supplied as empty, would
# not appear in it.
export TF_VAR_gitops_repo_url="${E2E_GITOPS_REPO_URL:-https://github.com/nanohype/eks-gitops}"
echo "  app-of-apps will point at $TF_VAR_gitops_repo_url"

# The development leaf sets enable_external_dns = true and declares
# `dependencies { paths = ["../dns"] }` to order the dns component ahead of it.
# This run applies six roots by name and never applies dns, so cluster-bootstrap
# reached for a parameter nothing had written:
#
#   Error: reading SSM Parameter
#   (/eks-agent-platform/development/dns/domain_filter): couldn't find resource
#
# Turned off here rather than adding dns to the run. The annotation it stamps is
# read by the addons-external-dns ApplicationSet, which this run never reaches,
# so applying dns would buy no coverage and would put a Route53 hosted zone —
# whose records are a classic teardown wedge — in front of the one path this
# campaign has proven works. If the run ever needs to cover external-dns, apply
# dns and drop this line; that is the faithful version.
#
# State it plainly: this is the second deliberate divergence from the development
# leaf, after the endpoint posture. A run that quietly differs from the
# configuration it claims to validate is its own dead control, so both are
# echoed at the top of every run.
export TF_VAR_enable_external_dns=false
echo "  external-dns annotation disabled (dns component is not in this run)"

# Every dependency edge the six roots declare, checked rather than assumed:
# cluster->network, secrets->cluster, agent-iam->{cluster,secrets},
# tenant-substrate->{cluster,network}, cluster-bootstrap->{cluster,network,dns}.
# `../dns` is the only one pointing outside the set, and the apply order below
# satisfies the rest.

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
# Every wait below this point — cert-manager, the operator, the tenant — depends
# on the addon catalog. When something in it cannot render, each of those waits
# still burns its full timeout and then blames its own subject, so the reported
# failure names a component that was never the problem. Two real cases:
#
#   an invalid label value on 30 ApplicationSets, which made every generated
#   Application fail admission, surfaced as "cert-manager-webhook not Available"
#
#   a CRD Application exceeding the repo-server's combined-manifest size limit,
#   which meant the WorkflowTemplate kind was never registered, surfaced as the
#   operator Deployment never appearing
#
# Three conditions, all required, because those two cases fail differently.
# Children > 0: an ApplicationSet that generates nothing leaves the parent Synced
# and Healthy over an empty catalog. Parent Synced: the first case. And no child
# carrying ComparisonError/InvalidSpecError: the second, where the parent was
# Healthy with 38 children and exactly one of them could not produce manifests.
# A child that is OutOfSync or Progressing is ordinary convergence and is not an
# error here; a child that cannot render at all is.
log "WAIT for the addon catalog (every wait below depends on it)"
aoa_sync="" aoa_children=0 aoa_broken="" aoa_start=$SECONDS aoa_next=0 aoa_elapsed=0
while [ $((SECONDS - aoa_start)) -lt 600 ]; do
  aoa_sync=$(kubectl -n argocd get application app-of-apps -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  aoa_children=$(kubectl -n argocd get applications --no-headers 2>/dev/null | grep -cv '^app-of-apps ' || true)
  # Select the two error condition types by name and print the owning
  # Application; awk keeps only the rows where a message was actually emitted.
  aoa_broken=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="ComparisonError")]}{.message}{end}{range .status.conditions[?(@.type=="InvalidSpecError")]}{.message}{end}{"\n"}{end}' 2>/dev/null |
    awk -F'\t' 'NF>1 && $2 != ""' || true)
  [ "$aoa_sync" = "Synced" ] && [ "${aoa_children:-0}" -gt 0 ] && [ -z "$aoa_broken" ] && break
  aoa_elapsed=$((SECONDS - aoa_start))
  if [ "$aoa_elapsed" -ge "$aoa_next" ]; then
    echo "  ...${aoa_elapsed}s: app-of-apps sync='${aoa_sync:-<absent>}' children=${aoa_children:-0}"
    aoa_next=$((aoa_elapsed + 60))
  fi
  sleep 10
done
if [ "$aoa_sync" != "Synced" ] || [ "${aoa_children:-0}" -eq 0 ] || [ -n "$aoa_broken" ]; then
  echo "  catalog did not converge — sync='${aoa_sync:-<absent>}' children=${aoa_children:-0}" >&2
  [ -n "$aoa_broken" ] && { echo "  Applications that cannot render:" >&2; printf '%s\n' "$aoa_broken" | cut -c1-300 | sed 's/^/    /' >&2; }
  kubectl -n argocd get application app-of-apps \
    -o jsonpath='{range .status.conditions[*]}  {.type}: {.message}{"\n"}{end}' 2>/dev/null >&2 || true
  # The per-resource sync messages carry an admission rejection verbatim; the
  # Application-level message only reports that some task failed.
  kubectl -n argocd get application app-of-apps -o json 2>/dev/null |
    python3 -c 'import json,sys
d=json.load(sys.stdin)
for r in d.get("status",{}).get("operationState",{}).get("syncResult",{}).get("resources",[]):
    if r.get("message"):
        print("  %s %s/%s: %s" % (r.get("status"), r.get("kind"), r.get("name"), r["message"][:400]))' >&2 || true
  kubectl -n argocd get applications 2>/dev/null | head -40 >&2 || true
  die "the addon catalog did not install — every wait below it would time out blaming its own subject"
fi
echo "  catalog Synced: $aoa_children Application(s), none blocked on rendering"

# secrets provisions the data CMK that agent-iam encrypts its model-artifacts +
# eval-reports buckets with (dependency.secrets.outputs.kms_key_arn). It MUST apply
# before agent-iam — the dependency's mock is restricted to validate/plan, so a
# missing secrets state fails the agent-iam apply loudly instead of baking the mock
# KMS ARN into real SSE-KMS + IAM config.
log "APPLY secrets"; tg secrets apply -auto-approve
log "APPLY agent-iam"; tg agent-iam apply -auto-approve

# tenant-substrate provisions every stateful store a tenant declares, and until
# now the run neither applied nor destroyed it — so the teardown's zero-billable
# check could not have seen an Aurora cluster or a cache even if one had been
# left standing.
#
# It applies against a map rendered from THIS RUN'S OWN tenant, not the
# environment's. The committed development map names the four real tenant apps
# and eighteen datastores; applying that here would provision them, and the
# destroy below would then delete them. The e2e tenant declares one keyValue
# store — enough to exercise create, tag, grant and destroy end to end, at
# DynamoDB on-demand prices rather than an Aurora cluster's.
log "RENDER tenant map for $TENANT"
# No $WORK/src staging step. Two lines here used to copy the rendered Platform CR
# into $WORK/src/<tenant>/platform.yaml, which nothing in this script ever read —
# scripts/render-tenants.py consumes that shape, and CI calls it, but this run
# writes tenants.generated.json directly in the heredoc below instead. They
# arrived with the heredoc that replaced them and stayed.
#
# Vestigial and also fatal: the file they copied FROM is produced by the tenant
# step further down, which clones the repo and helm-templates charts/tenant into
# it. So the copy ran before its own source existed and killed the run —
# `cp: .../tenants/development-platform/e2e-smoke.yaml: No such file or
# directory` — the first time an e2e ever reached this far.
cat >"$TENANTS_MAP" <<JSON
{
  "$TENANT": {
    "datastores": [
      { "name": "smoke", "kind": "keyValue",
        "deletion_policy": "Delete",
        "key_value": { "partition_key": { "name": "pk", "type": "S" } } }
    ]
  }
}
JSON
log "APPLY tenant-substrate"; tg tenant-substrate apply -auto-approve

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
opok="" op_start=$SECONDS op_next=0 op_elapsed=0
while [ $((SECONDS - op_start)) -lt 600 ]; do
  if kubectl -n eks-agent-platform get deploy eks-agent-platform-operator >/dev/null 2>&1 &&
    kubectl -n eks-agent-platform wait --for=condition=Available deploy/eks-agent-platform-operator --timeout=5s >/dev/null 2>&1; then
    opok=1
    break
  fi
  kubectl -n argocd annotate application eks-agent-platform-operator argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  op_elapsed=$((SECONDS - op_start))
  if [ "$op_elapsed" -ge "$op_next" ]; then
    echo "  ...${op_elapsed}s: operator Deployment not Available yet"
    op_next=$((op_elapsed + 60))
  fi
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
phase="" ph_start=$SECONDS ph_next=0 ph_elapsed=0
while [ $((SECONDS - ph_start)) -lt 720 ]; do
  phase=$(kubectl get platform "$TENANT" -n eks-agent-platform -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Ready" ] && break
  kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  ph_elapsed=$((SECONDS - ph_start))
  if [ "$ph_elapsed" -ge "$ph_next" ]; then
    echo "  ...${ph_elapsed}s: Platform phase='${phase:-<absent>}'"
    ph_next=$((ph_elapsed + 60))
  fi
  sleep 10
done
[ "$phase" = "Ready" ] || { dump_diag; die "Platform $TENANT did not reach phase=Ready (last: '${phase:-<absent>}')"; }
echo "  Platform $TENANT phase=Ready"

# --- 4. validate ------------------------------------------------------------
log "VALIDATE tenant-role conformance"
ROLE=$(kubectl get platform "$TENANT" -n eks-agent-platform -o jsonpath='{.status.iamRoleArn}')
[ -n "$ROLE" ] || die "Platform has no status.iamRoleArn"
RN="${ROLE##*/}"
# The operator GENERATES scoped inline policies on the tenant role — that is the
# mechanism, not a violation of it. bedrock-model-scoping is written on every
# non-suspended reconcile (operators/internal/controller/platform_model_scoping.go),
# and datastore-access / capability-access / tenant-secrets / tenant-key-access
# follow whatever the Platform spec declares. IAM even refuses DeleteRole while
# they exist. So "zero inline policies" is not conformance — it is the signature
# of a role the operator never finished reconciling, and asserting it here fails
# every correctly built tenant.
#
# The allowlist belongs to cloudgov (internal/platform/audit.go), and the
# `cloudgov platform audit` gate below enforces it in both directions: nothing
# outside the allowlist, and the model scope present. A second copy of that list
# here would be a copy that drifts, so this asserts only that the per-Platform
# model scope actually reached the role — the one thing whose absence means the
# tenant's Bedrock access is clamped by the baseline alone.
[ "$(aws iam list-role-policies --role-name "$RN" \
  --query "contains(PolicyNames, 'bedrock-model-scoping')" --output text)" = "True" ] ||
  die "tenant role $RN has no bedrock-model-scoping inline policy — the operator writes it on every non-suspended reconcile, so the per-Platform model scope is not in force"
# The boundary is checked by identity, not by presence. `grep -q boundary` would
# pass on any boundary whose ARN contains that word — including a wrong one, or
# one broader than the ceiling agent-iam mints. The isolation guarantee is that
# the tenant role is bounded by THIS policy, so the assertion reads the ARN
# agent-iam published and compares it exactly.
EXPECTED_BOUNDARY=$(tg agent-iam output -raw tenant_permissions_boundary_arn 2>/dev/null)
[ -n "$EXPECTED_BOUNDARY" ] ||
  die "agent-iam published no tenant_permissions_boundary_arn — nothing to compare against, so this check would assert nothing"
ACTUAL_BOUNDARY=$(aws iam get-role --role-name "$RN" --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)
[ "$ACTUAL_BOUNDARY" = "$EXPECTED_BOUNDARY" ] ||
  die "tenant role $RN boundary is '${ACTUAL_BOUNDARY}', expected '${EXPECTED_BOUNDARY}'"
echo "  tenant role $RN: bounded by $EXPECTED_BOUNDARY, model scope in force"

log "VALIDATE cloudgov platform audit"
(cd "$CLOUDGOV_DIR" && go build -o "$WORK/cloudgov" .)
"$WORK/cloudgov" platform audit --fail-on HIGH || die "cloudgov reported CRITICAL/HIGH findings"
echo "  cloudgov: no CRITICAL/HIGH findings"

RESULT="PASSED"
log "ALL GATES PASSED — tearing down"
