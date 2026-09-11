# ADR-0011: Zero-Downtime App Deploys via S3 Bundle + SSM

## Status

Accepted

## Date

2026-09-10

## Context

Every app change rode inside `user_data`, so every compose/Caddyfile tweak
replaced the whole instance (minutes dark, twice observed). "Deploy often"
(ADR-0002, ADR-0008) is incompatible with replacement-per-change.

## Decision Drivers

- **Must deploy app changes without replacement** — seconds of blip, not minutes dark.
- **Should keep host changes replacing** — user_data/type/SG changes still
  replace (rare by construction now).
- **Should keep one source of truth** — `app/` in git, not copies.

## Considered Options

### Option 1: S3 bundle + SSM rolling restart (chosen)

`app/compose.yaml` + `Caddyfile` live in a versioned S3 bucket.
`deploy-prod` uploads pre-plan (so fresh boots find it); `user_data`
fetches with retries instead of embedding content — so app-only pushes
plan empty and skip apply. New `deploy-app` job (app-file changes,
after `deploy-prod`): SSM `send-command` runs pull + `up -d` on the live
box, then the same 401 smoke test. Caddy keeps listening; blip is seconds.

- **Pros**: zero-downtime app deploys; rollback = revert + push (S3
  versioned too); boot and rolling path share the bundle.
- **Cons**: new IAM (deploy role: S3 RW + SSM send; instance: S3 read);
  one more pipeline job; SSM command polling complexity.

### Option 2: Blue-green instances + EIP flip (rejected)

Second box + flip per deploy: doubles steady cost, splits the data disk
across writers, and buys seconds over Option 1 a few times a month.

### Option 3: Keep replacing (rejected)

Status quo ante: the two outages that motivated this record.

## Decision

We will ship **app changes via S3 bundle + SSM rolling restart** and
reserve instance replacement for host changes.

## Rationale

It removes the only structural downtime source while adding cents of
infra and reusing every existing gate (smoke test, concurrency,
fail-open conditions).

## Consequences

### Positive

- App deploys: seconds, state preserved, sessions untouched.
- TF plan is empty on app-only pushes — the decoupling is structural,
  not a skip flag.

### Negative

- SSM command runner needs polling + timeout handling in the workflow.
- If SSM agent is down, rolling deploy fails (mitigation: falls back to
  the next host-changing deploy; alarm still pages on site-down).

## Implementation Notes

- `bundle.tf`: versioned, encrypted, private bucket + `app_bundle_bucket` output.
- `deploy-prod` uploads pre-plan and post-apply; `user_data` fetches with
  5-min retries; `deploy-app` runs pull + up via `AWS-RunShellScript`.
- Note 2026-09-11: the `app/stubs/aws` fake for the bootstrap build died
  with it (ADR-0007 amendment 4); the fetch path is proven by real
  deploys with retries, not by mock.

## Related Decisions

- ADR-0002 (pipeline this extends), ADR-0007 (compose stack deployed),
  ADR-0008 (state survives the rare replacements)

## References

- [SSM send-command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
