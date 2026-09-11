# Architecture Decision Records

Decisions behind this repo. Keep each record to 1–2 pages, be honest about
trade-offs, and never rewrite an accepted record — supersede it with a new one.

## Index

| ADR                               | Title                                  | Status   | Date       |
| --------------------------------- | -------------------------------------- | -------- | ---------- |
| [0001](0001-caddy-tls-proxy.md)   | Caddy as TLS reverse proxy for opencode web | Accepted | 2026-09-10 |
| [0002](0002-unified-ci-pipeline.md) | Single CI workflow with deploy-prod as a node | Accepted | 2026-09-10 |
| [0003](0003-supply-chain-hygiene.md) | Supply-chain and secret hygiene | Accepted | 2026-09-10 |
| [0004](0004-ssm-password.md)      | opencode password from SSM SecureString | Accepted | 2026-09-10 |
| [0005](0005-nipio-domain.md)        | nip.io generated domain instead of user-owned domain | Accepted | 2026-09-10 |
| [0006](0006-intrusion-alerting.md)  | Intrusion alerting via CloudWatch + SNS | Accepted | 2026-09-10 |
| [0007](0007-compose-deployment.md)  | Containerized deployment via compose | Accepted | 2026-09-10 |
| [0008](0008-data-volume.md)         | Persistent data volume for deploy-often | Accepted | 2026-09-10 |
| [0009](0009-uptime-monitoring.md)   | External uptime monitoring | Accepted | 2026-09-10 |
| [0010](0010-git-auth.md)            | Git identity and auth on the server | Accepted | 2026-09-10 |
| [0011](0011-rolling-deploys.md)     | Zero-downtime app deploys via S3 bundle + SSM | Superseded by 0015 | 2026-09-10 |
| [0012](0012-deploy-role.md)           | Deploy role and policy managed by bootstrap | Accepted | 2026-09-11 |
| [0013](0013-pipeline-bootstrap.md)     | Bootstrap applied by the pipeline | Accepted | 2026-09-11 |
| [0014](0014-github-sso-oauth2-proxy.md) | Passwordless GitHub SSO via oauth2-proxy | Accepted | 2026-09-11 |
| [0015](0015-blue-green-ready-gate.md) | Blue-green backends with a public /ready gate | Accepted | 2026-09-11 |
| [0019](0019-disk-memory-alerting.md) | Disk and memory alerting with bounded log growth | Accepted | 2026-09-11 |
| [0020](0020-nono-sandbox-spike.md) | Sandbox opencode with nono (spike verdict: adopt pilot, docker.sock cut) | Accepted | 2026-09-11 |
| [0021](0021-scale-to-zero-spike.md) | Scale-to-zero workers per project (spike verdict: reject) | Accepted | 2026-09-11 |
| [0022](0022-session-auto-recovery-spike.md) | Session auto-recovery (spike verdict: drain + diff-gated retry) | Accepted | 2026-09-11 |
| [0023](0023-global-config-precedence.md) | Managed global OpenCode config and merge precedence | Accepted | 2026-09-11 |
| [0024](0024-staged-user-data.md) | Staged user_data (bootstrap/app/monitoring) | Accepted | 2026-09-11 |
| [0025](0025-nono-sandbox-pilot.md) | nono sandbox pilot: vendored RPM + checked-in profile, docker.sock cut | Accepted | 2026-09-11 |
| [0026](0026-container-hardening.md) | Container hardening: cap_drop ALL, explicit opencode.json permissions, docker.sock residual risk | Accepted | 2026-09-11 |

## Creating a New ADR

1. Copy `template.md` to `NNNN-title-with-dashes.md` (next free number).
2. Fill it in, open a PR (or commit on `main` per repo flow), get it reviewed.
3. Add a row to the index above.

## Statuses

- **Proposed**: under discussion
- **Accepted**: decided, implement it
- **Deprecated**: no longer relevant
- **Superseded**: replaced by another ADR (link it)
- **Rejected**: considered but not adopted
