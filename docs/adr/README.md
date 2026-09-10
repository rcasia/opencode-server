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
