# fleet/aws/cluster-bootstrap

The plain-tofu entrypoint the [`eks-fleet`](https://github.com/nanohype/eks-fleet)
cluster factory runs **after** the cluster is Ready — the sibling root to
[`cluster-stack`](../cluster-stack). It pulls the kubernetes/helm/kubectl
providers (which `cluster-stack`, AWS-only, deliberately doesn't), so it lands in
its own root — the provider-boundary split the single-root decision allows.

The eks-fleet `Cluster` composition renders this as a **second** provider-opentofu
`Workspace`, feeding the cluster identity (endpoint, CA, OIDC) from the first
(`cluster-stack`) Workspace's outputs via `Cluster.status`. It wraps two existing
component modules — it does not reimplement them:

- `module.agent_iam` (`components/aws/agent-iam`) — the `<env>-eks-agent-platform-operator`
  IRSA role + tenant boundary/baseline (AWS), keyed on the cluster's OIDC.
- `module.cluster_bootstrap` (`components/aws/cluster-bootstrap`) — Cilium + ArgoCD +
  the in-cluster ArgoCD `Secret` (k8s/helm). The Secret carries the
  `eks-agent-platform/enabled` label + the OIDC/role annotations the eks-gitops
  `addons-agent-operator` ApplicationSet selects on, so the spoke's own ArgoCD
  reconciles the addon catalog onto itself (spoke-local).

`providers.tf` configures only the AWS provider (with the cross-account
`assume_role` hinge for the agent-iam side); `cluster_bootstrap` self-configures
the k8s/helm/kubectl/github providers from the cluster inputs, authenticating with
`aws eks get-token`.

## Run it by hand

```bash
tofu init -backend=false        # offline check — no S3, no AWS creds
tofu validate

# real run (provider-opentofu does this, with the S3 backend + assume_role):
tofu init \
  -backend-config=bucket=nanohype-eks-fleet-tfstate \
  -backend-config=key=fleet/<name>-bootstrap/terraform.tfstate \
  -backend-config=region=<region>
AWS_REGION=<region> tofu apply \
  -var region=<region> -var environment=dev -var team=platform \
  -var cluster_name=<name> -var cluster_endpoint=<https-endpoint> \
  -var cluster_certificate_authority_data=<base64-ca> \
  -var oidc_provider_arn=<arn> -var oidc_issuer=<host-no-scheme> -var vpc_id=<vpc>
```

## Cross-account note

The AWS provider's `assume_role` covers the agent-iam side cross-account. The
component's `aws eks get-token` uses **ambient** creds, so it reaches the spoke
API only when the runner already has cluster access. **Same-account works today**
(the hub is the cluster creator → admin). **Cross-account** needs a cluster-admin
EKS access entry for the hub role on the spoke cluster — a `cluster-stack`-side
follow-up, runtime-confirmed at the rung-2 vend.

## Sequencing + teardown caveats

- **Stand-up:** the composition renders this Workspace alongside cluster-stack, with
  the cluster-identity vars patched from `Cluster.status` (empty until cluster-stack
  is Ready). So this Workspace errors-and-retries (with the clear `cluster_endpoint`
  validation message) for the ~20–40 min the cluster takes, then converges. Benign,
  but noisy; the explicit gate (only render this once the cluster is Ready) rides the
  planned function-go-templating migration.
- **Teardown:** deleting the `Cluster` deletes both Workspaces with no ordering
  guarantee. This Workspace's `tofu destroy` needs the spoke's k8s API — if cluster-stack
  tears the cluster down first/in-parallel, destroy can't reach the API and the
  Workspace can wedge (and may hold the S3 state lock). Until ordered teardown is wired,
  delete this bootstrap Workspace first, or force-clean a wedged one. Tracked follow-up.

## Tenants repo

Setting `tenants_repo_url` requires `GITHUB_TOKEN` in the provider pod's environment
(the component registers a deploy key on that repo). Left empty (the default), the
github provider is declared but never called, so no token is needed.
