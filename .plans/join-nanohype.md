# Join nanohype org

Tactical plan for moving `stxkxs/landing-zone` → `nanohype/landing-zone`.

Master plan: `/Users/bs/.claude/plans/so-i-want-to-snazzy-sun.md` Phase 1.1.

## Transfer

```sh
gh repo transfer stxkxs/landing-zone nanohype
git remote set-url origin git@github.com:nanohype/landing-zone.git
```

GitHub auto-redirects the old URLs, but explicit references should still be cleaned up.

## Cross-references to fix

In-repo:

```sh
grep -rn "stxkxs" --include="*.md" --include="*.yaml" --include="*.hcl" --include="*.tf"
```

Known references:

- `CLAUDE.md:29` — points to `eks-gitops` (will also live under nanohype)
- `README.md` — likely contains the same companion-repo link
- `.github/workflows/*.yml` — drift-detection workflow creates GitHub issues; check for hardcoded org in any `gh` API calls

## OIDC trust policies

This is the biggest hazard. CI workflows use cloud OIDC federation:

- **AWS:** OIDC trust policies on the deploy/plan IAM roles likely include `token.actions.githubusercontent.com:sub` conditions of the form `repo:stxkxs/landing-zone:ref:refs/heads/main`. After transfer, GitHub issues tokens with the new path (`repo:nanohype/landing-zone:*`) and the trust check fails.
- **GCP:** Workload Identity Federation provider has a `attribute.repository` mapping; the binding likely allows `stxkxs/landing-zone`.
- **Azure:** Federated credential's `subject` field references the org/repo.

**Plan:** before the transfer, update all three cloud trust policies to accept either `stxkxs/landing-zone` OR `nanohype/landing-zone` for a window, then transfer, then drop the old principal once verified. Document the exact change per cloud in this file during execution.

## Verification

```sh
gh repo view nanohype/landing-zone                                     # 200
git remote -v                                                          # nanohype URL
grep -rn "stxkxs" --include="*.md" --include="*.yaml" --include="*.hcl" --include="*.tf"   # zero
make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network   # OIDC trust still works
```

## Notes

- Tofu state buckets (`{account_id}-{region}-tfstate`) have no org coupling — no state migration
- Terragrunt root config doesn't embed org name; safe
- LICENSE, CONTRIBUTING.md, SECURITY.md — verify they don't hardcode the old org
