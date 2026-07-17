# Threat Model

STRIDE analysis of the landing-zone substrate, organized by trust boundary. Each
boundary lists its primary threats, the mitigation **already in this repo** (with
the component that implements it), and the residual risk a fork should weigh.

This is the security reasoning behind [architecture.md](architecture.md)'s
Security Model section, pulled out so it can be reviewed on its own. It is a
model of the *substrate*; in-cluster workload posture lives in the eks-gitops
Kyverno policies and the eks-agent-platform operator.

## Trust boundaries

```
GitHub Actions ──OIDC──► AWS account ──► Terraform state (S3)
                              │
                              ├─► EKS control plane (public? IP-allowlisted)
                              │       │
                              │       └─► workloads ──Pod Identity/IRSA──► AWS APIs
                              │
                              ├─► org guardrails (SCPs) ── management account
                              └─► cross-account fleet vend (boundary + path gated)
```

## 1. CI/CD → AWS  (`github-oidc`)

- **Spoofing** — a foreign workflow assuming the deploy role. Mitigated: the
  trust policy is scoped to `repo:<org>/<repo>:*` and `github_repos` is validated
  non-empty (an empty list would drop the `sub` condition and let *any* Actions
  token assume the role). No long-lived keys; OIDC federation only.
- **Elevation of privilege** — the deploy role is powerful. Residual: scope it
  per-environment; do not share one role across development and production.
- **Repudiation** — CloudTrail records the assumed-role session; the `Revision`
  default tag (GITHUB_SHA) ties every mutation to a commit.

## 2. Terraform state  (`scripts/init-backend-aws.sh`, S3 backend)

- **Tampering / Information disclosure** — state holds resource metadata and some
  secrets material. Mitigated: S3 buckets are versioned + AES-256 encrypted, keyed
  `{env}/{component}/terraform.tfstate`, with native conditional-write locking
  (`use_lockfile`). Per-component/per-env state = isolated blast radius. The
  highest-value state buckets — `fleet-hub` (every vended cluster's OpenTofu state)
  and `portal-hub` (portal's cross-account state) — go further: SSE-KMS with a
  dedicated CMK, a bucket policy that denies any non-TLS request
  (`aws:SecureTransport=false`), and server access logging to a private sibling
  bucket.
- **Residual** — bucket policy and account-level SCPs are what keep state private;
  a fork should confirm the tfstate bucket is not readable outside the CI role.

## 3. EKS control plane  (`cluster`)

- **Information disclosure / Spoofing of the API server** — a world-open endpoint.
  Mitigated (fail-closed): `endpoint_public_access` defaults **false**; when true,
  variable validation *rejects* an empty `endpoint_public_access_cidrs` — there is
  no `0.0.0.0/0` fallback. Private access is always on. Secrets are envelope-
  encrypted with a KMS CMK (`encryption_config`).
- **Tampering** — cluster admin. Mitigated: `authentication_mode = API`, admin via
  a dynamically-mapped access entry (no hardcoded ARN); extra principals go through
  `access_entries` with real ARNs only.
- **Residual** — addon supply chain: versions are now pinned (`eks_addon_versions`)
  so an addon cannot silently roll to an unvetted build.

## 4. Workload identity  (`modules/aws/workload-identity`, tenant `irsa.tf`)

- **Spoofing / Elevation** — a pod assuming a role it should not. Mitigated: the
  `workload-identity` module mints **Pod Identity** roles whose trust is
  `pods.eks.amazonaws.com` only (no OIDC/web-identity principal), bound to an exact
  (cluster, namespace, service-account) via an EKS Pod Identity association. A
  `tofu test` gate asserts the trust never gains a web-identity action and that
  inline policies pass through unbroadened. Some components (e.g. druid) still use
  IRSA (OIDC trust scoped to a namespace/SA); both are per-tenant, one role each.
  The `workload-identity` module renders an optional per-statement `Condition`, so
  a caller's grant can be ARN-scoped **and** tag/StringEquals-locked. The addon and
  tenant grants use this: the AWS Load Balancer Controller's mutating EC2/ELB verbs
  are gated on the upstream `elbv2.k8s.aws/cluster` resource tag (it can only touch
  resources it created), argo-events' SQS/SNS access is scoped to the account/region
  (not `sqs:*`/`sns:*` on `*`), and each tenant's `kafka-cluster` grant is scoped to
  that tenant's own MSK cluster/topic/group ARNs. Feature-gated grants (gateway
  cognito/WAF) are omitted entirely when disabled rather than falling back to `*`.
- **Residual** — inline policy scope is the tenant author's responsibility; the
  module does not widen it, but it does not audit it either. Keep `Resource`
  scoped or condition-locked (the checkov gate enforces this at CI).

## 5. Cross-account fleet vend  (`fleet-vend`, `cluster` path/boundary vars)

- **Elevation of privilege** — a vended spoke minting roles outside its ceiling.
  Mitigated: the vend role's `iam:CreateRole`/`CreatePolicy` is double-locked — every
  role + the encryption policy must land under `cluster_iam_role_path`
  (`/eks-fleet/*`) **and** carry the vend permissions boundary
  (`iam:PermissionsBoundary` condition). A role that omits either is rejected by AWS
  at create time.
- **Residual** — the boundary policy itself is the ceiling; review its Deny
  statements, not just the Allows (the boundary-ceiling model is why the checkov
  IAM-wildcard skips are safe).

## 6. Org guardrails  (`org-scp`, `org-identity`, `break-glass`)

- **Tampering / Elevation at the org level** — disabling audit logging, leaving the
  org, using unapproved regions. Mitigated: `org-scp` attaches SCPs that Deny these
  regardless of account-level IAM.
- **Repudiation of emergency access** — Mitigated: `break-glass` roles fire an SNS
  alert on assumption and cap `max_session_duration` (default 1h). Identity Center
  (`org-identity`) provides 5 least-privilege permission sets rather than shared
  admin.

## 7. Denial of service

- **Cluster** — system nodes hitting DiskPressure mid-converge (a real past
  incident). Mitigated: `system_node_disk_size` sizes the Bottlerocket data volume
  explicitly with a `>= 50` validation, and Cilium's WireGuard/health ports are
  opened on the node SG.
- **State** — concurrent applies corrupting state. Mitigated by the S3 lockfile.
- **Residual** — this is a single-region template by design (documented in
  `.checkov.yaml`); regional outage is an accepted trade-off a regulated fork must
  revisit.

## What this model excludes

- In-cluster runtime posture (PSS/best-practice admission, image signing) — owned
  by the eks-gitops Kyverno policies.
- AI-platform budget/model guardrails — owned by the eks-agent-platform operator
  (see that repo's runbooks).
- Application-layer threats inside tenant workloads.
