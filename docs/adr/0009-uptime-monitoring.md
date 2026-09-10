# ADR-0009: External Uptime Monitoring

## Status

Accepted

## Date

2026-09-10

## Context

ADR-0006 pages on attackers, and the pipeline smoke test proves the site on
deploys — but nothing watches the site *between* deploys. Caddy died
silently (exit 127, no restart) and the outage was found by a human
refreshing a browser. Embarrassing for a box whose job is being reachable.

## Decision Drivers

- **Must detect dead externally** — host-level checks (EC2 status) stay
  green when the app is down; only an outside HTTPS probe sees the truth.
- **Must not weaken auth or pollute metrics** — probes can't need the
  password and can't count as login failures.
- **Should cost cents** — same bar as ADR-0006.

## Considered Options

### Option 1: Route53 health check on a Caddy `/ping` carve-out (chosen)

`handle /ping { respond "ok" 200 }` in Caddy answers *before* the proxy,
so it needs no credentials and never reaches opencode (stays out of the
401 login-probe metric). Route53 hits it every 30s; 3 failures page via
the existing SNS topic. ~$0.50/mo, no hosted zone needed.

- **Pros**: outside perspective, 90-second detection, reuses the alarm topic.
- **Cons**: $0.50/mo; another moving part (accepted: fully managed).

### Option 2: CloudWatch Synthetics canary (rejected)

Scripted browser checks at ~$1.70/day for 1-minute frequency — two orders
of magnitude over budget for "is it up".

### Option 3: Third-party uptime service (rejected)

Free tiers exist, but that's another account, another secret, another
dependency — for what AWS sells for fifty cents.

## Decision

We will probe **`https://<domain>/ping` via Route53** (30s, 3 strikes)
and alarm to the existing SNS topic, with `/ping` also asserted by
`make test-boot`.

## Rationale

It closes the exact gap that bit us (silent app death, green host), at
negligible cost, without touching auth or metrics.

## Consequences

### Positive

- Next silent death pages within ~2 minutes instead of waiting for a human.
- `/ping` doubles as a credential-free check for scripts and test-boot.

### Negative

- $0.50/mo (called out per repo rule 8).
- A `/ping` path exists on the public site (accepted: static "ok", no info).

## Implementation Notes

- `app/Caddyfile`: `/ping` handle before the proxy.
- `modules/monitoring`: `aws_route53_health_check` + `site-down` alarm
  (both skipped when `domain_name` is empty).
- Deploy role needs `route53:*` on health checks (IAM addition, same as
  the Monitoring statement pattern).

## Related Decisions

- ADR-0001 (public 443 is what's being watched)
- ADR-0006 (intrusion alerting — same topic, different signal)
- ADR-0007 (`/ping` asserted in test-boot)

## References

- [Route53 health checks](https://docs.aws.amazon.com/route53/latest/developerguide/dns-failover.html)
