# ADR-0003: Supply-Chain and Secret Hygiene

## Status

Accepted

## Date

2026-09-10

## Context

The pipeline executes third-party code on every run (GitHub Actions,
Terraform provider) and the repo could plausibly collect credentials
(tfvars, passwords, tokens). A compromised action tag or a leaked secret
would hit prod automatically, because deploys are automatic (ADR-0002).

## Decision Drivers

- **Must run known-good third-party code** — tags and branches are mutable.
- **Must keep humans in the update loop** — bumps get reviewed, never
  silently auto-merged.
- **Must never commit secrets** — state, tfvars, keys, passwords stay out
  of git by construction, not by discipline alone.

## Considered Options

### Dependency updates

- **Dependabot defaults (weekly, ungrouped)**: noisy PR stream, encourages
  rubber-stamping — rejected.
- **Daily scan + 21-day cooldown, grouped, max 5** (chosen): PRs appear at
  most ~monthly per ecosystem, batched, so each one gets a real review
  including a release-date check. Security updates bypass the cooldown by
  Dependabot design — accepted, that's the point of the bypass.

### Action references

- **Mutable tags (`@v4`)** (rejected): a retagged upstream runs new code in
  our pipeline with no diff.
- **SHA pins with version comments** (chosen): immutable; updates arrive as
  Dependabot diffs showing old → new SHA plus the human-readable version.

### Secret scanning

- **Nothing** (rejected): leaks caught only by eyeballs.
- **detect-secrets pre-commit hook with audited baseline** (chosen): blocks
  new findings at commit time; the baseline records the three reviewed
  false positives (Moto `test` creds, prose) as `is_secret: false`.

## Decision

We will take **daily grouped Dependabot updates with a 21-day cooldown**,
**SHA-pin every GitHub Action**, require a **release-date check before
merging any bump**, and enforce **detect-secrets at commit time**.

## Rationale

Each layer covers the others' gap: pins make execution reproducible,
Dependabot PRs make updates visible, the cooldown + release check make them
reviewable, and detect-secrets guards the repo contents themselves.

## Consequences

### Positive

- Every third-party change in the pipeline is an explicit, dated, reviewed diff.
- New secrets are blocked before they reach git history.

### Negative

- SHA bumps are noisier diffs than tag bumps (mitigation: version comments).
- The 21-day delay means living slightly behind latest (accepted: stability
  over novelty for infra; security updates still come fast).
- Baseline needs re-audit if real findings ever appear (that's the job).

## Implementation Notes

- `.github/dependabot.yml`: `github-actions` + `terraform`, daily,
  `cooldown.default-days: 21`, groups, `limit: 5`, `prefix: chore`.
- `.pre-commit-config.yaml`: `Yelp/detect-secrets` with `.secrets.baseline`.
- Precedent: AWS provider 5.x → 6.x merged only after a same-week audit
  (no config changes needed); a same-day override is allowed with an
  explicit audit, never by default.

## Related Decisions

- ADR-0002 (the pipeline this hygiene protects)
- ADR-0004 (secret handling for the app password)

## References

- [Dependabot cooldown](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/configuring-access-to-private-registries-for-dependabot)
- [detect-secrets](https://github.com/Yelp/detect-secrets)
