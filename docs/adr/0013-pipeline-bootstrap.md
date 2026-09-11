# ADR-0013: Bootstrap Applied by the Pipeline

## Status

Accepted

## Date

2026-09-11

## Context

ADR-0012 put the deploy trust in `bootstrap/` but still applied it from
a laptop. Standing rule since: **prod is pipeline-only — no laptop
touches, including bootstrap and recovery**. A trust stack that needs a
laptop to evolve breaks that rule on every IAM change.

## Decision Drivers

- **Must close the loop** — every prod mutation, IAM included, ships as
  a commit through `ci`.
- **Must adopt, not rebuild** — the manual role, OIDC provider, and
  state bucket already exist; the pipeline takes them over in place.
- **Must leave no residue** — the one-time manual grant deletes itself
  once Terraform owns the policy.

## Considered Options

### Option 1: bootstrap CI job assuming the deploy role (chosen)

A `bootstrap` job runs before `deploy-prod`, applies `bootstrap/` with
its own S3 state, imports the manual resources idempotently, converges
the TF-managed policy, then deletes the manual bridge policy.

- **Pros**: steady state is 100% pipeline; the bridge is self-cleaning.
- **Cons**: the role needs scoped self-management (it can edit exactly
  its own role/policy/OIDC — acceptable: whoever controls `main`
  controls the policy anyway).

### Option 2: Keep bootstrap on laptop state

- **Cons**: every future permission miss needs a laptop — violates the
  standing rule. Rejected.

## Decision

Bootstrap ships via the `bootstrap` CI job. The deploy policy carries
`DeploySelf` + `DeployOIDC` + `StateBucket` statements so the role can
converge its own trust. The manual bridge is a single inline policy
named `bridge`, deleted by the job once the plan goes through.

## Rationale

The chicken-and-egg (who creates the first role) is solved once, by
hand, in the smallest possible surface: one inline policy. Everything
after that — including the deletion of that policy — is a commit.

## Consequences

### Positive

- `AccessDenied` in any job → fix `bootstrap/deploy.tf`, push, pipeline
  heals itself (after the bridge exists).
- Bootstrap state lives in S3 next to root state; no laptop holds it.

### Negative

- First green needs the manual bridge (one console edit, documented below).
- `prod-deploy` concurrency serializes bootstrap + deploy-prod + deploy-app.

### Risks

- A bad bootstrap apply can lock out deploys (role trust broken) —
  mitigation: trust block changes get extra review; recovery is the same
  bridge procedure.

## Implementation Notes

- `.github/workflows/ci.yml`: `bootstrap` job (OIDC, S3 init with
  `opencode-server/bootstrap/terraform.tfstate`, `import ... || true`
  for bucket + sub-resources + role + OIDC provider, plan gate,
  apply, `delete-role-policy bridge`).
- `bootstrap/versions.tf`: partial `backend "s3" {}` (same pattern as root).
- `bootstrap/deploy.tf`: `DeploySelf` (role + policy ARNs only),
  `DeployOIDC` (this provider only), `StateBucket` (state pattern only).
- Bridge policy (console → IAM → `opencode-server-deploy` → inline
  policy named `bridge`):
  - `s3:*Bucket*` + versioning/encryption/PAB/tagging on
    `arn:aws:s3:::opencode-prod-app-bundle-816079798250` and `-tfstate-*`
    (deploy-prod create path + bootstrap bucket adoption)
  - `s3:Get/Put/DeleteObject` on both buckets' `opencode-server/*` and
    bundle `app/*` (state backend + bundle upload)
  - `s3:ListBucket` on both buckets, `s3:ListAllMyBuckets`
  - `iam:*` on the deploy role, its policy, and the OIDC provider
    (adoption + convergence)
  - `sts:GetCallerIdentity`
- The bootstrap test (`test-bootstrap.sh`) stays a local `make` target —
  too slow for the pipeline by explicit choice.

## Related Decisions

- ADR-0002 (the pipeline this job joins)
- ADR-0011 (the bundle bucket whose denial started this)
- ADR-0012 (TF-owned trust; apply mechanism refined here)

## References

- [Terraform import blocks vs CLI import](https://developer.hashicorp.com/terraform/language/import)
