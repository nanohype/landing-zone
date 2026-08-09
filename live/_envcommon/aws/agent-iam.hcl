terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/agent-iam"
}

dependency "cluster" {
  config_path = "../cluster"
  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/mock"
    oidc_issuer       = "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    cluster_name      = "mock-eks"
  }
  # `destroy` is in this list because a teardown is not always a first teardown.
  #
  # Without it, a dependency whose state is already empty cannot be resolved, and the
  # dependent leaf fails at PARSE — `Unknown variable; There is no variable named
  # "dependency"` — before terragrunt can work out that there is nothing left to destroy.
  # A re-run against a torn-down platform then reports a failure per leaf, which is
  # exactly the recovery path rackctl prescribes ("re-run `rackctl destroy`; it is
  # idempotent") and exactly where it stopped being true. Observed as 9 spurious failures
  # against an account with no billable resources left in it.
  #
  # A mock value cannot cause the wrong thing to be deleted: a destroy targets the
  # resource ids recorded in state, not the inputs. The inputs only configure providers,
  # and a provider built from a mock fails loudly rather than deleting something else.
  #
  # The merge strategy is the half that actually does the work, and allowing `destroy`
  # without it changes nothing. Terragrunt substitutes mocks for a dependency that has
  # never been APPLIED; a dependency that was applied and then destroyed has state, and
  # that state is empty — so `tofu output -json` returns {} rather than failing, and
  # terragrunt reports "detected no outputs" instead of reaching for the mocks. `shallow`
  # fills in only the keys the state does not supply, which on a live dependency is none
  # of them: the mocks are inert exactly when the real values exist.
  #
  # `init` is in the list because every orchestrator runs it first. rackctl issues
  # `terragrunt --working-dir <leaf> --non-interactive init` before each verb, for its own
  # module-cache reasons, so the dependency has to resolve at init or the destroy behind it
  # never executes. Testing this with a bare `terragrunt destroy` passes and proves nothing —
  # that is a different command from the one the tool runs.
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

# The secrets component's KMS key encrypts the model-artifacts + eval-reports
# buckets. Both are post-cluster fan-out components, so this edge just orders
# secrets before agent-iam on the core chain — agent-iam still applies before
# ArgoCD brings the operator up.
dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  oidc_provider_arn = dependency.cluster.outputs.oidc_provider_arn
  oidc_issuer       = dependency.cluster.outputs.oidc_issuer
  cluster_name      = dependency.cluster.outputs.cluster_name
  data_kms_key_arn  = dependency.secrets.outputs.kms_key_arn
  team              = "platform"
}
