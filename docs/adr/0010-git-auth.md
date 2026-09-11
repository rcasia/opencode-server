# ADR-0010: Git Identity and Auth on the Server

## Status

Accepted

## Date

2026-09-10

## Context

The agent must commit and push as the operator (identity + credentials),
but neither may live in git, tfvars, images, or logs.

## Decision Drivers

- **Must keep the token out of git/state/images** — same bar as ADR-0004.
- **Should be idempotent and re-runnable** — token rotation and late
  cloning must not need a redeploy.
- **Should not gate boot on git** — a git misconfiguration must never
  take the site down (precedent: telemetry tolerance, ADR-0007).

## Considered Options

### Option 1: SSM token + boot helper (chosen)

Identity (`git_user_name/email`) travels as plain TF vars — commit
identity is public by design. The PAT lives in an SSM SecureString;
`/usr/local/bin/opencode-git-setup.sh` (written by `user_data`) fetches
it at boot and configures the container (`credential.helper store` +
`~/.git-credentials`, 600). Helper warns instead of failing boot and can
be re-run any time.

- **Pros**: no secrets in git/state/images; rotation = update parameter +
  re-run helper; reuses the ADR-0004 pattern the operator already knows.
- **Cons**: one more manual SSM step (documented next to the password one).

### Option 2: Bake credentials into a custom image (rejected)

Secrets in image layers, rebuild per rotation — violates the must-have.

### Option 3: Manual setup only (rejected)

Works once, rots immediately: every redeploy wipes container config...
actually volumes persist it, but rotation/repair stay tribal knowledge.
The helper makes the manual path a command, not a wiki page.

## Decision

We will store the PAT in SSM, identity in TF vars, and configure both
via an **idempotent boot helper that warns instead of failing**.

## Rationale

Same secret-handling shape as the web password, with boot decoupled from
git health.

## Consequences

### Positive

- Agent commits/pushes work out of the box after the one-time SSM step.
- Rotation is parameter + helper re-run, no deploy.

### Negative

- PAT needs `contents: read/write` on the operator's repos — a real
  credential on the box (mitigation: fine-grained PAT scoped to those
  repos only, rotation documented).

## Implementation Notes

- Vars: `git_user_name/email`, `github_token_parameter`
  (default `/opencode/github-token`).
- `user_data.sh` writes + runs the helper after `compose up`; helper
  waits up to 5 min for the container, then configures or warns.
- `app/stubs/docker` fakes `exec`/`ps` so the bootstrap build covers the
  helper wiring; assertion greps the stub log.
- Correction 2026-09-11: the wait is 10 min (slow first pulls won the
  5-min race), the helper verifies `credential.helper` stuck, and the
  `deploy-app` SSM step re-runs the helper — container replacement wipes
  gitconfig, so boot-only application left app deploys without git auth.
  (The AL2023-execution test that once covered the helper was removed
  the same day as too slow; see ADR-0007 amendment 4.)

## Related Decisions

- ADR-0004 (password pattern reused)
- ADR-0007 (bootstrap test covers the helper)

## References

- [Git credential storage](https://git-scm.com/docs/git-credential-store)
