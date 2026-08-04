# Unit tests for org-identity — the SSO permission sets, groups, and the account
# assignments that turn a declared permission set into a role someone can actually
# assume. An unassigned permission set is the failure mode worth testing for: it
# renders in the console, reads correctly in a policy review, and materializes as no
# IAM role in any account, so every property attributed to it is aspirational.
#
# Assignments resolve accounts by NAME. Ids are real identifiers and this is a public
# tree, and a pasted id goes stale in silence the day an account is recreated — the
# assignment still applies, to nothing.
#
# Runs at command = plan against a mocked provider. The organization is mocked with two
# accounts so org-wide fan-out is distinguishable from "assigned to one thing".

mock_provider "aws" {
  # Identity Store group ids are validated against a UUID shape by the provider, so a
  # generated mock value fails before any assertion runs.
  mock_resource "aws_identitystore_group" {
    defaults = {
      group_id = "12345678-1234-1234-1234-123456789012"
    }
  }
  # Likewise the permission-set ARN: the assignment resource parses it, so a generated
  # mock string fails the parse before any assertion runs.
  mock_resource "aws_ssoadmin_permission_set" {
    defaults = {
      arn = "arn:aws:sso:::permissionSet/ssoins-mock/ps-mock0123456789"
    }
  }
  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns               = ["arn:aws:sso:::instance/ssoins-mock"]
      identity_store_ids = ["d-mock123456"]
    }
  }
  mock_data "aws_organizations_organization" {
    defaults = {
      accounts = [
        {
          id               = "111111111111"
          name             = "workload-production"
          arn              = "arn:aws:organizations::111111111111:account/o-mock/111111111111"
          email            = "prod@example.test"
          state            = "ACTIVE"
          status           = "ACTIVE"
          joined_method    = "CREATED"
          joined_timestamp = "2026-01-01T00:00:00Z"
        },
        {
          id               = "222222222222"
          name             = "workload-development"
          arn              = "arn:aws:organizations::222222222222:account/o-mock/222222222222"
          email            = "dev@example.test"
          state            = "ACTIVE"
          status           = "ACTIVE"
          joined_method    = "CREATED"
          joined_timestamp = "2026-01-01T00:00:00Z"
        },
      ]
    }
  }
}

variables {
  environment = "org"
  region      = "us-west-2"
  team        = "platform"
  groups = {
    auditors = { description = "Read-only auditors" }
  }
  permission_sets = {
    Auditor = {
      description      = "Read-only auditor"
      session_duration = "PT4H"
      managed_policies = []
      inline_policy    = null
      boundary_policy  = null
    }
  }
}

# An auditor that reads one account of several is not auditing. org_wide_assignments
# must fan out over EVERY account the organization reports — so adding an account
# cannot quietly leave it outside the audit surface.
run "org_wide_assignment_reaches_every_account" {
  command = plan

  variables {
    org_wide_assignments = [
      { group = "auditors", permission_set = "Auditor" },
    ]
    account_assignments = []
  }

  assert {
    condition     = length(aws_ssoadmin_account_assignment.this) == 2
    error_message = "one org-wide assignment over a two-account organization must produce two assignments; a single one means the fan-out collapsed and the second account is unaudited"
  }

  assert {
    condition = length(setsubtract(
      toset(["111111111111", "222222222222"]),
      toset([for a in aws_ssoadmin_account_assignment.this : a.target_id]),
    )) == 0
    error_message = "org-wide assignments must target every account id the organization reports, resolved from the org rather than from a written-down list"
  }
}

# Declaring nothing must assign nothing — the failure this component previously had
# (account_assignments = []) should stay reachable and obvious rather than being
# papered over by a default.
run "nothing_declared_assigns_nothing" {
  command = plan

  variables {
    org_wide_assignments = []
    account_assignments  = []
  }

  assert {
    condition     = length(aws_ssoadmin_account_assignment.this) == 0
    error_message = "with no assignments declared the component must create none — an implicit assignment is access nobody asked for"
  }
}

# A named assignment resolves the id from the organization, never from the input.
run "named_assignment_resolves_the_id_from_the_org" {
  command = plan

  variables {
    org_wide_assignments = []
    account_assignments = [
      { group = "auditors", permission_set = "Auditor", account_name = "workload-production" },
    ]
  }

  assert {
    condition = alltrue([
      for a in aws_ssoadmin_account_assignment.this : a.target_id == "111111111111"
    ])
    error_message = "a named assignment must resolve to the id the organization reports for that name"
  }
}

# The one that matters. A name the organization does not have must FAIL THE APPLY.
# Absorbing it quietly is the shape this whole component is vulnerable to: terraform
# green, policy review clean, and a person who believes they have access who does not.
#
# What this run pins precisely: an unresolvable name must not VANISH. Filtering such
# entries out of the assignment map — the tempting tidy-up, and the dangerous one —
# produces no resource, satisfies no expected failure, and fails this run.
#
# What it does not pin: which layer rejects it. With the precondition removed the
# resource still fails, because an empty target_id is not a valid account id, so this
# run passes either way. The precondition earns its place by naming the account in the
# error rather than by being the thing that fails; that message is not assertable here.
run "an_unknown_account_name_fails_the_apply" {
  command = plan

  variables {
    org_wide_assignments = []
    account_assignments = [
      { group = "auditors", permission_set = "Auditor", account_name = "workload-typo" },
    ]
  }

  expect_failures = [
    aws_ssoadmin_account_assignment.this,
  ]
}
