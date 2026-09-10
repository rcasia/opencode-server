# ADR-0006: Intrusion Alerting via CloudWatch + SNS

## Status

Accepted

## Date

2026-09-10

## Context

Port 443 is intentionally public (ADR-0001: roaming phones + Let's Encrypt),
so internet scanners and login probers will reach Caddy. SSH stays on a
`/32`, but brute force there must still be visible. Nobody watches logs by
hand — probing must page the operator by email.

## Decision Drivers

- **Must detect login brute force** on opencode web (HTTP 401 bursts) and
  **SSH probing** (sshd failures).
- **Should cost cents** — no GuardDuty (~$/mo scale), no WAF/ALB (rejected
  in ADR-0005 as overkill).
- **Should add no servers** — agent on the existing instance, managed
  AWS services only.

## Considered Options

### Option 1: CloudWatch agent + metric filters + alarms + SNS email (chosen)

`amazon-cloudwatch-agent` ships Caddy JSON access logs and `/var/log/secure`
to log groups (30-day retention); a `{ $.status = 401 }` filter counts login
failures (alarm at ≥20/5min) and a phrase filter counts sshd failures
(alarm at ≥3/5min); both notify an SNS topic with an email subscription.

- **Pros**: pennies per month, no new hosts, thresholds tunable in Terraform.
- **Cons**: email delivery (no paging/SMS); SNS subscription needs one
  confirmation click (out-of-band step, documented).

### Option 2: GuardDuty (rejected)

Full threat intel (flow/DNS logs) but dollars per month for a single host
and findings tuned for fleets — cost and noise both wrong for one box.

### Option 3: fail2ban only (rejected)

Bans attackers (useful) but tells nobody — solves blocking, not alerting.
Complements Option 1; deferred, not a substitute.

## Decision

We will alert via **CloudWatch Logs metric filters → alarms → SNS email**,
with the agent deployed through `user_data` and all thresholds in
`modules/monitoring`.

## Rationale

It is the only option under ~$1/mo that pages a human for both attack
vectors with zero new infrastructure to operate.

## Consequences

### Positive

- Probers trigger an email within ~5 minutes; logs retained 30 days for forensics.
- The address arrives via the `ALERT_EMAIL` Actions variable
  (`TF_VAR_alert_email`); absent means the subscription is skipped but the
  alarms still exist.

### Negative

- Operator typos can trip the 401 alarm (accepted: 20/5min is generous).
- Log ingestion + alarm metrics cost cents (called out per repo rule 8).
- Deploy role needs `sns/logs/cloudwatch` permissions (one-time IAM addition).

## Implementation Notes

- `modules/monitoring`: topic, conditional email subscription, two log
  groups, two metric filters, two alarms.
- `modules/compute`: `CloudWatchAgentServerPolicy` attachment;
  `user_data.sh` installs `rsyslog` + agent, Caddyfile gains a JSON
  `access.log`.
- Operator steps: set the `ALERT_EMAIL` Actions variable, click the SNS
  confirmation email.

## Related Decisions

- ADR-0001 (public 443 is why this exists)
- ADR-0005 (rejected WAF/ALB cost options)

## References

- [CloudWatch metric filters](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
