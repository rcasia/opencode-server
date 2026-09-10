# ADR-0005: nip.io Generated Domain Instead of User-Owned Domain

## Status

Accepted

## Date

2026-09-10

## Context

ADR-0001 required a user-owned domain with a manual A record so Caddy could
obtain a Let's Encrypt certificate. The operator has no domain they want to
use and no tunneling — they want an AWS-side generated name that just works
from a phone.

## Decision Drivers

- **Must keep valid TLS** (ADR-0001 stands: no cleartext basic auth).
- **Should need zero setup** — no registrar, no DNS panel, no account.
- **Should cost nothing** — no ALB, no CloudFront, no hosted zone.

## Considered Options

### Option 1: EC2 public hostname (rejected)

`ec2-54-170-161-9.eu-west-1.compute.amazonaws.com` is free and automatic,
but no CA will issue for `amazonaws.com` — TLS would be self-signed (phone
cert warnings) or absent (credential leak). Fails the must-have.

### Option 2: `nip.io` wildcard DNS (chosen)

`54-170-161-9.nip.io` resolves to the EIP with no setup. `nip.io` is on the
Public Suffix List, so Let's Encrypt issues for it normally via HTTP-01
(port 80 is already open for Caddy). Free, no account.

- **Pros**: zero setup, valid cert, EIP is stable so the name is stable.
- **Cons**: depends on a free third-party DNS operator; hostname is
  derived from the public IP (guessable — accepted: security rests on TLS
  + password, not obscurity); if the EIP ever changes, `domain_name` must
  be updated to match.

### Option 3: CloudFront `*.cloudfront.net` in front (rejected)

Valid Amazon cert, but CloudFront→origin would cross the internet over HTTP
(same sniffing problem), plus data-transfer cost and complexity — worse on
every driver.

### Option 4: ALB with ACM (rejected)

ACMs can't issue for `amazonaws.com` either, and an ALB adds ~$16/mo —
fails cost and TLS both.

## Decision

We will point Caddy at **`<eip-with-dashes>.nip.io`** (`domain_name` in
`environments/prod.tfvars`) and let it obtain Let's Encrypt TLS as designed
in ADR-0001. A user-owned domain remains a drop-in replacement later
(same var, plus an A record).

## Consequences

### Positive

- Phone access with zero DNS/account setup and a warning-free cert.
- Nothing in the infra changes except one variable value.

### Negative

- Third-party DNS dependency for name resolution (mitigation: trivially
  replaceable with a owned domain or `sslip.io` later).
- EIP change = rename + redeploy (EIP is attached and survives replacement,
  so this should be rare).

## Related Decisions

- ADR-0001 (Caddy TLS proxy — this relaxes its "user-owned domain" requirement)

## References

- [nip.io](https://nip.io)
- [Let's Encrypt + Public Suffix List](https://letsencrypt.org/docs/integration-guide/)
