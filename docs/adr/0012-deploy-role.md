# ADR-0012: Deploy Role and Policy Managed by Bootstrap

## Status

Accepted

## Date

2026-09-11

## Context

The `opencode-server-deploy` role (GitHub OIDC → AWS) was created by
console clicks with a hand-attached policy. That broke exactly the way
click-ops breaks: the S3 app-bundle bucket (ADR-0011) needed
`s3:CreateBucket`, the manual policy only had object RW, and the first
apply that created the bucket died `AccessDenied` — after destroying
the live instance.

## Decision Drivers

- **Must be versioned** — permission changes get review like any infra change.
- **Must be reproducible** — a fresh account rebuilds the same trust.
- **Should stay least-privilege** — the deploy role gets what the root
  stack manages plus what CI calls directly, nothing more.

## Considered Options

### Option 1: bootstrap owns deploy trust (chosen)

`bootstrap/` creates the OIDC provider, the deploy role, and its
policy. Applied once with user credentials; the root stack runs AS the
role and never manages it.

- **Pros**: misses become reviewed fixes; one documented recovery
  (re-apply bootstrap).
- **Cons**: one-time migration off the manual role (delete or import).

### Option 2: Keep the manual role, document the policy

- **Cons**: the failure that motivated this ADR, on repeat — rejected.

## Decision

Bootstrap owns the full deploy trust (`bootstrap/deploy.tf`): OIDC
provider, `opencode-server-deploy` role, explicit-action policy.

## Rationale

The blast radius of a wrong policy is a dead prod (proven). Versioning
it puts the fix where the review is. The trust boundary stays clean:
user credentials create the role once, the role creates everything else,
and nothing manages itself.

## Consequences

### Positive

- `AccessDenied` in `deploy-prod` → add the action in `bootstrap/`,
  push, re-apply bootstrap, re-run. No console.
- Thumbprint derived via `tls_certificate` — survives CA rotations.

### Negative

- New AWS services need a bootstrap policy change first.
- Trust keeps the old `StringLike repo:<repo>:*` scope for now; tightening
  to the environment subject is future work.

### Risks

- Bootstrap mis-applied with weak credentials locks out deploys —
  mitigation: bootstrap runs locally with the account owner, once.

## Implementation Notes

- `bootstrap/deploy.tf`: provider + role + `aws_iam_policy` +
  attachment; `github_repo` var, `deploy_role_arn` output.
- Policy shape: explicit actions, name-scoped resources where the API
  allows (`opencode-*-ec2-role`, `*-alerts`, bucket patterns); `*` only
  where the API requires it (Describe*, tagging on create, health
  checks, SSM send).
- Migrating: delete the console role + OIDC provider and let bootstrap
  recreate them, or `terraform import` both into bootstrap state.

## Related Decisions

- ADR-0002 (the pipeline that assumes this role)
- ADR-0003 (supply-chain: no click-ops on the trust path)
- ADR-0011 (the bundle bucket whose creation denial caused this)

## References

- [Configuring OpenID Connect in Amazon IAM (AWS)](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)

## Correction (2026-09-11, pre-deploy)

Two lines above went stale within hours and are corrected here, not
rewritten: trust is NOT the slug pattern — this is an EMU org, so the
`sub` claim carries numeric IDs and only the exact `StringEquals`
subject works (`deploy_subject` var; a loose replacement locked the
pipeline out the same day). Bootstrap is NOT laptop-applied either —
see ADR-0013, which refines the apply mechanism to the pipeline.
