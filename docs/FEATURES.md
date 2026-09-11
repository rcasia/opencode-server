# Intended Features

What this repo is supposed to do. This is the contract: if behavior
diverges from this file, fix the code — or change the contract here
deliberately, with an ADR where the repo rules require one. Agents:
keep this file updated on every behavior-changing commit (see AGENTS.md
rule 10).

## Ship

- **Push-to-deploy.** `git push origin main` runs one `ci` graph:
  checks (`pre-commit`, `terraform`, `local`) → `bootstrap` (deploy
  trust) → `deploy-prod` (plan, apply on changes only, smoke test) →
  `deploy-app` (app-file changes only). PRs run checks only, never
  deploy. Empty plans skip apply/upload/smoke. Gates fail open.
  (`.github/workflows/ci.yml`, ADR-0002)
- **Zero-downtime app deploys.** `app/` ships as a versioned S3 bundle;
  app-only changes pull + restart containers via SSM with seconds of
  blip, never replacing the host. Rollback = revert + push.
  (`bundle.tf`, ADR-0011)
- **Cattle hosts.** Any `user_data` change replaces the instance
  (`user_data_replace_on_change`); EIP and data volume survive.
  (ADR-0008)

## Serve

- **Phone-friendly HTTPS opencode.** Caddy terminates TLS (Let's Encrypt
  over `nip.io`) and proxies to `opencode web` on localhost; SSM-backed
  password, `401` auth gate, unauthenticated `/ping` for probes.
  (`app/`, ADR-0001, ADR-0005)
- **Persistent state.** 10 GB encrypted EBS at `/var/lib/docker`:
  sessions, images, workspace, and certs survive replacement. Only a
  full destroy wipes it. (ADR-0008)
- **Agent git identity.** The agent commits/pushes as the operator:
  identity in vars, PAT in SSM, applied by an idempotent boot helper
  (10-min wait + verify) and re-applied on every app restart.
  (`modules/compute/user_data.sh`, ADR-0010)

## Watch

- **Intrusion alerting.** Caddy 401 bursts (≥20/5 min) and sshd failures
  (≥3/5 min) ship to CloudWatch and page via SNS email.
  (`modules/monitoring`, ADR-0006)
- **Uptime probe.** Route 53 hits `/ping` every 30s, pages after 3
  failures — outside the login-failure metric. (`modules/monitoring`,
  ADR-0009)
- **Audit trail.** Every apply stamps the commit SHA as `DeployedRef`
  (instance + disk) and `deployed_version`; plans are kept as 30-day
  artifacts. (`outputs.tf`)

## Trust

- **Pipeline-owned everything.** The deploy role, OIDC provider, and
  four scoped policy shards live in `bootstrap/` and are applied by the
  `bootstrap` CI job — which the role assumes itself. One-time manual
  adoption uses a self-deleting `bridge` policy. (`bootstrap/`,
  ADR-0012, ADR-0013)
- **Pipeline-only ops, no reads either.** No laptop plans, applies,
  backends, outputs, shells, or console edits. Review plans via
  artifacts. From-zero rebuild is console seeds + pipeline (README
  "Rebuilding from zero").
- **Secrets discipline.** Secrets live in SSM SecureStrings or GitHub
  secrets, never in git/state/logs. `detect-secrets` gates commits.
  (ADR-0003, ADR-0004)

## Sustain

- **Cheap by design.** Single AZ public subnet, no NAT, `t3.small`, EIP
  attached, ~$0.50/mo probes + ~$0.80/mo data disk. Cost-increasing
  changes must be called out.
- **Supply-chain hygiene.** SHA-pinned actions, Dependabot (21-day
  cooldown) for actions/terraform/compose-image pins, `tag@digest`
  images. (ADR-0003)
- **Local testability.** Moto mock (`make local-up/plan-local/apply-local`,
  no credentials) plus `make test-boot` (compose chain with dummy env).
  Moto catches config errors, never real-AWS behavior.

## Out of scope

- Multi-region, HA, staging environments.
- SSH-first access (SSM preferred; keys optional and empty by default).
- Manual deploys, laptop backends, long-lived AWS keys.
