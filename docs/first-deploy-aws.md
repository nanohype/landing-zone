# First-Time AWS Deploy

Walkthrough for provisioning a brand-new AWS environment from a fresh account through to a running EKS cluster reconciled by ArgoCD against `eks-gitops`.

Assumes you have an AWS account and `root` access (the email/password used to sign up). If you don't, see [Account & Identity Setup](#account--identity-setup) first.

## Prerequisites

| Tool | Install | Why |
|---|---|---|
| AWS CLI v2 | `brew install awscli` | sign-in, account ops, quota |
| OpenTofu | `brew install opentofu` | resource provisioning |
| Terragrunt | `brew install terragrunt` | environment orchestration |
| kubectl | `brew install kubectl` | post-deploy verification |
| Task | `brew install go-task/tap/go-task` | runs the Taskfile wrappers |

## Account & Identity Setup

The root account (the email you signed up with) should never be used for daily work. Bootstrap an IAM Identity Center admin user instead.

### 1. Enable IAM Identity Center

This is the AWS equivalent of Microsoft Entra ID — federated SSO sitting on top of IAM.

1. Sign in as root at <https://signin.aws.amazon.com> using the signup email
2. Console → search **"IAM Identity Center"** → click **Enable**
3. Pick an **Identity source**: Identity Center directory (built-in) is the simplest. Microsoft Entra ID or Okta if you have them.
4. Note your **AWS access portal URL** (looks like `https://d-1234567890.awsapps.com/start`)

### 2. Create your admin user

IAM Identity Center → **Users → Add user**:

- Username: `<yourname>-admin`
- Email: a real address you control (must verify)
- First/Last name: yours
- Display name: `<Your Name> Admin`

After creation, set the user's password via the email verification link.

### 3. Create a permission set + assign

IAM Identity Center → **Permission sets → Create permission set**:

- Predefined permission set → **AdministratorAccess**
- Session duration: 12 hours
- Name: `AdministratorAccess`

Then **AWS accounts** → select your account → **Assign users or groups** → pick `<yourname>-admin` → attach the `AdministratorAccess` permission set.

### 4. Enable MFA on the admin user

IAM Identity Center → **Settings → Authentication → MFA settings**:

- Prompt users for MFA: **Every time they sign in**
- MFA types: **Authenticator apps** (TOTP)

When you next sign in as `<yourname>-admin`, you'll be forced to enroll. Use any TOTP app (1Password, Authy, Microsoft/Google Authenticator).

### 5. Lock down the root account

While still signed in as root, AWS console → top-right account name → **Security credentials**:

- **Account security recommendations** → MFA → **Assign MFA device** → register a TOTP method
- Generate a long random password (64+ chars) → store in password manager. You should not use root for anything except billing and account-deletion scenarios.

Sign out as root. Sign in via the IAM Identity Center portal URL as `<yourname>-admin` from now on.

### 6. Configure local CLI

```bash
aws configure sso
# SSO start URL: <your access portal URL>
# SSO Region: us-east-1 (or wherever Identity Center is hosted)
# CLI default region: us-west-2
# CLI default output: json
# Profile name: workload-dev (or whatever)

aws sso login --profile workload-dev
aws sts get-caller-identity --profile workload-dev
```

Export `AWS_PROFILE=workload-dev` (or set it per-shell) so Terragrunt picks it up automatically.

## Pre-Deploy Setup

### 7. Update `account.hcl`

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "account: $ACCOUNT_ID"
```

Edit `live/aws/workload-<env>/account.hcl`:

```hcl
locals {
  account_id    = "<your-account-id>"
  account_alias = "workload-<env>"
}
```

### 8. Bootstrap the state backend

Creates an S3 bucket `{account_id}-{region}-tfstate` with versioning + encryption. Idempotent.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
./scripts/init-backend-aws.sh $ACCOUNT_ID us-west-2
```

### 9. Service quotas

AWS imposes per-region quotas on resources like EC2 instances, EIPs, NAT Gateways, and VPCs. Defaults for a new account are very tight (e.g., 5 EIPs, 5 VPCs per region, 32 vCPUs for On-Demand standard instances).

Check current limits:

```bash
aws service-quotas list-service-quotas --service-code ec2 --region us-west-2 \
  --query "Quotas[?QuotaCode=='L-1216C47A'].{Quota:QuotaName,Limit:Value}" \
  --output table
```

`L-1216C47A` is "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances." For prod EKS with Karpenter, you want at least 256.

File an increase via console or CLI:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 256 \
  --region us-west-2
```

Most On-Demand quota increases are auto-approved within 15-30 minutes. EIP increases can take longer (manual review).

### 10. Decide on public vs private cluster endpoint

Production overlay defaults `cluster_endpoint_public_access = false`. Without a bastion or VPN, you can't `kubectl` against the cluster from your laptop. For initial deploys, flip to `true` in `live/aws/workload-prod/us-west-2/production/cluster/terragrunt.hcl`. You can flip back later once jump-host access is set up.

## Deploy

```bash
cd <repo-root>

task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=network            # ~3-5 min
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=cluster            # ~15-25 min
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=secrets            # ~2 min
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=cluster-bootstrap  # ~5-10 min
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=cluster-addons     # ~5-10 min
```

Replace `<env>` with `dev`/`staging`/`production` and account accordingly.

### Get kubectl access (after `cluster` succeeds)

```bash
aws eks update-kubeconfig --name <env>-eks --region us-west-2 --profile workload-<env>
kubectl get nodes
```

### Watch the GitOps reconcile (after `cluster-bootstrap`)

```bash
kubectl -n argocd get applications --watch
```

Bootstrap creates the App-of-Apps Application pointing at `eks-gitops`. Applications progress `OutOfSync` → `Syncing` → `Healthy` over ~15-25 min. Karpenter provisions nodes as addons schedule.

## Post-Deploy

### Wire IRSA role ARNs into eks-gitops

`cluster-addons` outputs the real role ARNs that need to replace the `000000000000` placeholders:

```bash
cd live/aws/workload-<env>/us-west-2/<env>/cluster-addons
terragrunt output -json irsa_role_arns
terragrunt output -json s3_bucket_names
```

Edit each `eks-gitops/addons/*/values-<env>.yaml`, replace the placeholder account IDs with the real values. Open PR → merge → ArgoCD reconciles.

### Verify

```bash
kubectl -n argocd get applications
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Optional Add-Ons

```bash
# Amazon Managed Prometheus + Amazon Managed Grafana
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=managed-monitoring

# Druid analytics tenant
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=druid

# Route 53 hosted zone (if attaching ingress hostnames)
task apply CLOUD=aws ACCOUNT=workload-<env> REGION=us-west-2 ENVIRONMENT=<env> COMPONENT=dns
```

After `managed-monitoring`, bootstrap the Amazon Managed Grafana service-account token into Secrets Manager (one-time):

```bash
AMG_ID=$(cd live/aws/workload-<env>/us-west-2/<env>/managed-monitoring && terragrunt output -raw grafana_workspace_id)

SA=$(aws grafana create-workspace-service-account \
  --workspace-id $AMG_ID \
  --grafana-role ADMIN \
  --name terraform \
  --query serviceAccount.id --output text)

TOKEN=$(aws grafana create-workspace-service-account-token \
  --workspace-id $AMG_ID \
  --service-account-id $SA \
  --name token \
  --seconds-to-live 2592000 \
  --query serviceAccountToken.key --output text)

aws secretsmanager create-secret \
  --name eks-grafana-token \
  --secret-string "{\"token\":\"$TOKEN\"}"
```

## Cost Reality

Approximate $/day at default sizes:

| Setting | Dev | Production |
|---|---|---|
| EKS control plane | $2.40 | $2.40 |
| System node pool | $4-6 (1-2× m5.large) | $14 (3× m5.large) |
| Karpenter-provisioned addons | $5-15 | $25-50 |
| NAT Gateways (3) + EIPs | $3 | $3 |
| S3 + EBS | $0.50 | $1.50 |
| Secrets Manager + Route 53 | $0.30 | $0.30 |
| **Baseline** | **~$15-25/day** | **~$45-70/day** |
| +Managed monitoring (AMP+AMG) | +$3/day | +$5-8/day |
| +Druid | +$40/day | +$50/day |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `aws sso login` opens browser but auth never completes | popup blocker, or wrong start URL | Verify URL with `aws configure sso list`. Try `aws sso login --no-browser` for a code-based flow. |
| `Unable to locate credentials` from terragrunt | `AWS_PROFILE` not set | `export AWS_PROFILE=workload-<env>` |
| `task init-backend` says `Usage:` | Taskfile not forwarding args | Run directly: `./scripts/init-backend-aws.sh $ACCOUNT_ID us-west-2` |
| `terragrunt: Working dir components/aws/X does not exist` | envcommon source path bug | Path must be `${dirname(find_in_parent_folders("cloud.hcl"))}/../../components/...` (`../..`) |
| `LimitExceeded: ... vCPUs ... cannot be increased` during cluster | quota too low | Request increase via Service Quotas console / `aws service-quotas request-service-quota-increase` |
| EKS cluster create fails with `InvalidParameterException` re: SG/subnet | network module didn't fully complete | Re-apply `network`, then re-apply `cluster` |
| `cluster-bootstrap` connects but fails RBAC | IAM principal not in cluster access entries | Update `live/aws/workload-<env>/.../cluster/terragrunt.hcl` access_entries map, re-apply `cluster` |
| ArgoCD apps stuck in OutOfSync, "repository not accessible" | eks-gitops URL wrong or repo private | Verify https://github.com/nanohype/eks-gitops loads anonymously |
| Addons stuck Pending | Karpenter not provisioning | `kubectl get nodepool && kubectl describe nodepool default` |
