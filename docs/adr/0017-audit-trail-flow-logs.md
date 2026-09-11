# ADR-0017: Account Audit Trail + VPC Flow Logs

## Status

Accepted

## Date

2026-09-11

## Context

ADR-0006 pages on probes but keeps no who-did-what: a compromised key or
console click leaves no trace. One host, one region, cents-only budget.

## Decision Drivers

- **Must record management events** (IAM, EC2, S3 policy changes).
- **Must record network flows** for the single-host VPC post-incident.
- **Should cost cents** — no CloudTrail Lake, no GuardDuty (ADR-0006).

## Considered Options

### Option 1: Single-region trail + Flow Logs to CloudWatch (chosen)

`aws_cloudtrail` (management events, validated files) to a dedicated
audit bucket (SSE, versioning, PAB, 90d noncurrent expiry); `aws_flow_log`
(ALL traffic) to a 30d log group via a minimal delivery role.

- **Pros**: cents/month, managed services only, no new hosts.
- **Cons**: single-region (cross-region calls invisible); 30d flow window.

### Option 2: Multi-region trail + S3 flow delivery (rejected)

Full coverage but more events stored longer — cost and noise wrong for
one box. Revisit if the estate grows past one region.

## Decision

We will audit via **single-region CloudTrail + VPC Flow Logs**, buckets
and roles in `modules/monitoring` / `modules/network`, deploy perms in
`bootstrap/deploy.tf`. No unencrypted-put deny on buckets that take
service-writer delivery (CloudTrail / S3 access logs do not send the SSE
header; bucket-default AES256 already encrypts at rest).

## Consequences

- Forensics exist for API + network events; the trail bucket may merge
  with the access-log buckets (separate prefixes) as a follow-up.
- Deploy role gains trail/flow-log/S3-audit perms (least-privilege adds).
