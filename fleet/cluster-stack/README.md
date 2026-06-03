# fleet/cluster-stack

The plain-tofu entrypoint the [`eks-fleet`](https://github.com/nanohype/eks-fleet)
cluster factory runs.

`eks-fleet` vends clusters from a `Cluster` claim; its Crossplane composition
renders a provider-terraform `Workspace` that runs **this** root. provider-terraform
runs the `tofu` binary, not `terragrunt`, so it can't point at a `components/aws/*`
directory directly — those rely on terragrunt-generated provider blocks +
`_envcommon` dependency wiring. This root makes both explicit:

- `providers.tf` — the AWS provider (region, default_tags, optional cross-account
  `assume_role`) terragrunt would otherwise generate from `root.hcl`.
- `main.tf` — the `network → cluster` chain `_envcommon/aws/cluster.hcl` would
  otherwise wire via a `dependency` block.

It **wraps** the existing component modules — it does not reimplement them. When
the cluster module gains a variable, add it here and to the eks-fleet `Cluster` XRD.

## Run it by hand

```bash
tofu init -backend=false        # offline check — no S3, no AWS creds
tofu validate

# real run (provider-terraform does this, with the S3 backend + assume_role):
tofu init \
  -backend-config=bucket=nanohype-eks-fleet-tfstate \
  -backend-config=key=fleet/<name>/terraform.tfstate \
  -backend-config=region=<region>
AWS_REGION=<region> tofu apply \
  -var region=<region> -var environment=dev -var team=platform \
  -var assume_role_arn=arn:aws:iam::<account>:role/terraform-vend   # omit for same-account
```

## Scope

Today: `network → cluster`. Next: `cluster-bootstrap` + `agent-iam` — they pull
the kubernetes/helm providers, so they belong in a sibling root the composition
runs as a second Workspace, after the cluster's kubeconfig exists.
