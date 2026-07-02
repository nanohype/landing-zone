# Model-Access Cutover: Binding an App Workload to Its Tenant Role

The procedure for moving an app's pods onto the operator-reconciled tenant
role — the sequence that makes `Platform.spec.identity` the single place an
app's Bedrock model access is declared, with zero loss of access for live
pods.

## Why a sequence exists at all

Two owners meet at this seam:

- **This repo (tofu)** owns the slow-moving substrate: the app's DDB tables,
  queues, buckets, keys, secrets — and the `<app>-<env>-app-access` managed
  policy + EKS Pod Identity association in `components/aws/<app>-platform/`.
- **The eks-agent-platform operator** owns the fast-moving per-tenant IAM
  state: the `<env>-<app>-tenant` role, the agent-iam baseline attachment
  (the Bedrock *grant*, `bedrock:InvokeModel*` on `*`), the
  `bedrock-model-scoping` inline policy (the *clamp*, a deny on everything
  outside `spec.identity.allowedModels` / `allowedModelFamilies`), and the
  `extraPolicyArns` attachments.

The effective model surface on the tenant role is **grant ∩ clamp**: the
baseline allows all invoke, the scoping policy denies everything the spec
doesn't name. The clamp grants nothing on its own — so every grant an app
pod needs must be attached to the tenant role (baseline via operator,
app-access via `extraPolicyArns`) **before** the pod's Pod Identity
association points at that role. Applying steps out of order is how a live
pod loses model or substrate access.

## Per-app parameters

| App | Tenant role (per env) | App-access policy | Association SA | Module state address (old role) |
| --- | --- | --- | --- | --- |
| slack-knowledge-bot | `<env>-slack-knowledge-bot-tenant` | `slack-knowledge-bot-<env>-app-access` | `slack-knowledge-bot` | `module.slack_knowledge_bot_irsa` |
| digest-pipeline | `<env>-digest-pipeline-tenant` | `digest-pipeline-<env>-app-access` | `digest-pipeline` | `module.digest_pipeline_irsa` |
| incident-response | `<env>-incident-response-tenant` | `incident-response-<env>-app-access` | `incident-response` | `module.incident_response_irsa` |
| competitive-intelligence | `<env>-competitive-intelligence-tenant` | `competitive-intelligence-<env>-app-access` | `competitive-intelligence` | `module.competitive_intelligence_irsa` |

Declared model sets (each app's `platform.yaml`, matching what the app's
config actually invokes):

| App | `spec.identity.allowedModels` |
| --- | --- |
| slack-knowledge-bot | `us.anthropic.claude-sonnet-4-6`, `amazon.titan-embed-text-v2:0` |
| digest-pipeline | `anthropic.claude-sonnet-4-6` |
| incident-response | `anthropic.claude-sonnet-4-6`, `anthropic.claude-haiku-4-5` |
| competitive-intelligence | `us.anthropic.claude-sonnet-4-20250514-v1:0`, `us.anthropic.claude-sonnet-4-6`, `amazon.titan-embed-text-v2:0` |

All commands below assume: `ENV` (dev/staging/production), `APP`, `ACCT`
(the workload account id), `NS=tenants-protohype`, region `us-west-2`, and a
kubeconfig for the env's cluster. Run one env at a time, dev → staging →
production, completing every verification before the next env.

## Step 0 — Preconditions

The operator on the cluster must be a build that reconciles model scoping
(the `Platform` status carries a `ModelAccessScoped` condition), and the
Platform CR must be applied and `Ready`.

```bash
kubectl get platform "$APP" -n "$NS" \
  -o jsonpath='{.status.phase}{"\n"}{.status.conditions[?(@.type=="ModelAccessScoped")].reason}{"\n"}'
# expect: Ready + Scoped (or DenyByDefault before the spec update)

aws iam get-role --role-name "$ENV-$APP-tenant" \
  --query 'Role.{Arn:Arn,Boundary:PermissionsBoundary.PermissionsBoundaryArn}'
# expect: the tenant role exists, carrying the agent-iam tenant boundary
```

Also confirm the widened tenant boundary (agent-iam) has applied in this
env — the app's substrate actions are clipped without it:

```bash
task apply ACCOUNT=workload-$ENV REGION=us-west-2 ENVIRONMENT=$ENV COMPONENT=agent-iam
aws iam get-policy-version \
  --policy-arn "arn:aws:iam::$ACCT:policy/eks-agent-platform/$ENV-eks-agent-platform-tenant-boundary" \
  --version-id "$(aws iam get-policy --policy-arn "arn:aws:iam::$ACCT:policy/eks-agent-platform/$ENV-eks-agent-platform-tenant-boundary" --query Policy.DefaultVersionId --output text)" \
  --query 'PolicyVersion.Document.Statement[?Sid==`TenantWorkloadCeiling`].Action' | grep dynamodb
```

## Step 1 — Mint the app-access policy (tofu, additive)

```bash
cd live/aws/workload-$ENV/us-west-2/$ENV/$APP-platform
terragrunt apply -target=aws_iam_policy.app_access
terragrunt output app_access_policy_arn
```

Additive only — nothing about the running pods changes. Record the ARN.

## Step 2 — Declare the grant in the Platform CR (operator)

In the app repo, fill `spec.identity.extraPolicyArns` with the step-1 ARN
(the `allowedModels` set is already declared in `platform.yaml`), then:

```bash
kubectl apply -f platform.yaml
kubectl wait platform "$APP" -n "$NS" --for=condition=ModelAccessScoped --timeout=120s
```

Verify the effective role state directly on IAM — the operator must have
attached the grant and written the clamp before anything is re-pointed:

```bash
aws iam list-attached-role-policies --role-name "$ENV-$APP-tenant"
# expect: <env>-eks-agent-platform-tenant-baseline + <app>-<env>-app-access

aws iam get-role-policy --role-name "$ENV-$APP-tenant" --policy-name bedrock-model-scoping
# expect: DenyUnscopedBedrockInvoke with NotResource covering exactly the
# app's declared models (inference-profile + foundation-model ARN pairs)
```

Then prove the intersection (boundary ∩ baseline ∩ clamp ∩ app-access)
authorizes what the app does — simulate before any pod depends on it:

```bash
TENANT_ROLE_ARN=$(aws iam get-role --role-name "$ENV-$APP-tenant" --query Role.Arn --output text)

# a declared model → allowed
aws iam simulate-principal-policy --policy-source-arn "$TENANT_ROLE_ARN" \
  --action-names bedrock:InvokeModel \
  --resource-arns "arn:aws:bedrock:us-west-2:$ACCT:inference-profile/us.anthropic.claude-sonnet-4-6" \
  --query 'EvaluationResults[].EvalDecision'
# expect: ["allowed"]

# an undeclared model → explicitDeny (the clamp working)
aws iam simulate-principal-policy --policy-source-arn "$TENANT_ROLE_ARN" \
  --action-names bedrock:InvokeModel \
  --resource-arns "arn:aws:bedrock:*::foundation-model/meta.llama3-70b-instruct-v1:0" \
  --query 'EvaluationResults[].EvalDecision'
# expect: ["explicitDeny"]

# one substrate action per service the app touches (e.g. slack-knowledge-bot)
aws iam simulate-principal-policy --policy-source-arn "$TENANT_ROLE_ARN" \
  --action-names dynamodb:GetItem kms:Encrypt sqs:SendMessage \
  --resource-arns "arn:aws:dynamodb:us-west-2:$ACCT:table/slack-knowledge-bot-$ENV-tokens" \
  --query 'EvaluationResults[].{a:EvalActionName,d:EvalDecision}'
# expect: allowed across the board — a clipped action here means the
# boundary or app-access policy is missing something; STOP and fix
```

Do not proceed past a failed simulation.

## Step 3 — Re-point the Pod Identity association (tofu, in-place)

The association resource moves from the retired module address to the
component's `aws_eks_pod_identity_association.app`. A state move keeps EKS's
one-association-per-(namespace, SA) invariant intact — the apply is an
in-place `UpdatePodIdentityAssociation` of `role_arn`, never a
destroy/create gap:

```bash
terragrunt state mv \
  "<module state address>.aws_eks_pod_identity_association.this" \
  "aws_eks_pod_identity_association.app"
terragrunt apply -target=aws_eks_pod_identity_association.app
```

Running pods keep their cached old-role credentials (still valid — the old
role is untouched until step 4). Restart so every pod picks up tenant-role
credentials now, on your clock:

```bash
kubectl rollout restart deployment -n "$NS" -l "app.kubernetes.io/name=$APP"
kubectl rollout status  deployment -n "$NS" -l "app.kubernetes.io/name=$APP" --timeout=300s
```

Verify identity and behavior:

```bash
aws eks list-pod-identity-associations --cluster-name "<env cluster>" \
  --namespace "$NS" --service-account "$APP"
# then describe-pod-identity-association → roleArn == the tenant role

POD=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NS" "$POD" -- sh -c \
  'wget -qO- "$AWS_CONTAINER_CREDENTIALS_FULL_URI" --header "Authorization: $(cat $AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE)"' \
  | grep -o '"AccessKeyId"'   # credentials vend from the Pod Identity agent
```

Then the app-level smoke: exercise one model call and one substrate write
through the app itself (a real query for slack-knowledge-bot, a dry-run
digest for digest-pipeline, a test incident for incident-response, a manual
crawl tick for competitive-intelligence) and watch the logs for any
`AccessDenied` / `AccessDeniedException`.

## Step 4 — Retire the old role (tofu, destructive)

Only after step 3's verifications. The remaining diff is exactly the old
`<app>-<env>-platform` role and its inline policy — the last place a
Bedrock model ARN was ever written in tofu:

```bash
terragrunt plan    # must show ONLY the module role + inline policy destroys
terragrunt apply
terragrunt plan    # converges to zero diff

aws iam get-role --role-name "$APP-$ENV-platform" 2>&1 | grep NoSuchEntity
```

Model access is now declared once — in `Platform.spec.identity` — and
enforced once, by the operator's clamp over the baseline grant.

## Rollback

- **After step 1 or 2:** nothing user-visible changed. Revert `platform.yaml`
  if desired; the clamp and attachments affect only a role no app pod uses
  yet. Deleting the app-access policy requires detaching it first (it's
  operator-attached): clear `extraPolicyArns`, wait a reconcile, then
  `terragrunt destroy -target=aws_iam_policy.app_access`.
- **After step 3, before step 4:** the old role still exists. Move the state
  back (`terragrunt state mv` in reverse), `terragrunt apply
  -target=<module state address>.aws_eks_pod_identity_association.this` to
  re-point `role_arn` at the old role, and rollout-restart. Total exposure
  is one association update + one restart.
- **After step 4:** roll forward from git — revert the component's commit and
  apply (recreates the old role, inline policy, and module-owned
  association), `terragrunt state mv` the association back to the module
  address first so the apply is an update, then rollout-restart.

## Fresh-environment ordering

On a brand-new environment there is no cutover, only ordering. The
association resolves the tenant role by name (`data.aws_iam_role.tenant`),
so:

1. `agent-iam` applies (boundary, baseline, operator role).
2. The Platform CR applies with `extraPolicyArns: []`; wait `Ready`.
3. The `<app>-platform` component applies (substrate + app-access policy +
   association onto the tenant role).
4. `extraPolicyArns` gets the `app_access_policy_arn` output; re-apply the
   CR; wait `ModelAccessScoped`.
5. The app's ApplicationSet entry syncs.

## Semantics that change at this seam

- **Kill-switch now reaches app pods.** A BudgetPolicy breach at 120%
  detaches the baseline from the tenant role — the app's model access zeroes
  instantly while substrate access (app-access via `extraPolicyArns`)
  persists, so the app degrades to its no-LLM behavior instead of falling
  over. This is the intended budget boundary; before the consolidation the
  kill-switch could not stop app-driven Bedrock spend at all.
- **One privilege domain per Platform.** App pods and AgentFleet pods
  (`tenant-runtime` SA) share the tenant role: fleet workloads inherit the
  app-access grants. The Platform is the isolation boundary; workloads that
  must not share substrate access belong in separate Platforms.
- **Model changes are spec changes.** Pointing an app at a new model is a
  `platform.yaml` edit (`spec.identity.allowedModels`) + `kubectl apply` —
  no tofu plan, no IAM edit, converged by the operator in one reconcile.
