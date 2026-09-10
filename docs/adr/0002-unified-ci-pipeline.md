# ADR-0002: Single CI Workflow with deploy-prod as a Node

## Status

Accepted

## Date

2026-09-10

## Context

The repo previously had two workflows: `ci` (checks) and `deploy`
(triggered by `workflow_run` after `ci`). That split caused a detached build
graph — two runs per push, two badges, workflow-wide `id-token: write`, and
confusion about which run actually shipped prod. The goal, following Fowler's
[Continuous Integration](https://martinfowler.com/articles/continuousIntegration.html),
is one self-testing build: every push builds, and merging to `main` ships
prod automatically once the checks pass.

## Decision Drivers

- **Must have one build graph** — a single run shows checks and deploy
  together; red is unambiguous.
- **Must auto-deploy on green `main`** — no manual gate, no `workflow_dispatch`
  click step.
- **Must never deploy from PRs** — secrets and the state bucket stay
  untouched on pull requests.
- **Should keep PR feedback fast** — the slow AWS work must not gate commits.

## Considered Options

### Option 1: deploy-prod job inside `ci` (chosen)

`deploy-prod` runs in the same workflow, `needs: [pre-commit, terraform,
local]`, with `if: push to main`. Job-scoped OIDC permission plus
`concurrency: prod-deploy` so applies never overlap.

- **Pros**: one run, one badge, deploy visibly gated on checks; PR runs get
  checks only for free.
- **Cons**: `main` pushes take ~2–4 min instead of ~1 (the deploy stage rides
  along); PRs can't preview the real prod plan.

### Option 2: Separate `deploy` workflow on `workflow_run` (status quo ante)

- **Cons**: two runs per push, deploy detached from the checks that gated it,
  broader OIDC permissions — rejected as the confusion that motivated this ADR.

### Option 3: Manual `workflow_dispatch` deploy

- **Cons**: a human click per release reintroduces a manual gate and toil —
  rejected; automation is the point.

## Decision

We will ship prod via a **`deploy-prod` job in the single `ci` workflow**,
running only on `push` to `main` after the three check jobs pass, using OIDC
(plan `-out=tfplan` → apply → smoke test), with the plan kept as a 30-day
artifact. Moto (`local` job) is a labeled mock that catches config errors —
never a prod clone; the prod `plan` inside `deploy-prod` is the gate that
sees the real environment.

## Rationale

One graph satisfies all four drivers at once, and the costs (slower `main`
runs, no PR prod-preview) fall exactly where they hurt least: `main` pushes
are releases, and Moto already covers config shape on PRs.

## Consequences

### Positive

- `git push origin main` is the entire release process; PRs are check-only.
- Missing secrets (`AWS_ROLE_ARN` / `TF_STATE_BUCKET`) fail red instead of
  silently skipping — misconfiguration is visible.
- Empty plans skip apply/upload/smoke (`-detailed-exitcode` gate), so
  no-change pushes cost seconds, not an apply.

### Negative

- Red `main` stops the line: nothing new is pushed until it is green again
  (revert first if the cause isn't obvious).
- No per-environment approvals: `environment: prod` has zero protection
  rules by design — the green checks ARE the gate.

### Risks

- A bad apply still ships automatically — mitigation: plan artifact review,
  smoke test (`aws ec2 wait instance-running`), EIP surviving replacement,
  revert-on-red discipline.

## Implementation Notes

- `.github/workflows/ci.yml`: `deploy-prod` needs the three checks,
  `environment: prod`, `concurrency: prod-deploy`, OIDC (`id-token: write`)
  scoped to that job only.
- IAM used by deploys: `opencode-server-deploy` role + trust policy with
  immutable `sub` (see repo summary in `main` history, 2026-09-10).

## Related Decisions

- ADR-0003 (supply-chain hygiene gates what the pipeline executes)
- ADR-0004 (how the deployed app gets its password)

## References

- [Continuous Integration (Fowler)](https://martinfowler.com/articles/continuousIntegration.html)
- [opencode Server docs](https://opencode.ai/docs/server/)
