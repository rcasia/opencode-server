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
  backend colors (`opencode-blue`/`opencode-green`, one live) switch via
  `switch.sh` over SSM: the idle color starts, must answer authed `GET /`
  through Caddy, and only then does the live color stop — Caddy (stable
  edge, health-checked `first`-policy failover) retries instead of
   failing, Caddyfile changes apply via `caddy reload`, and a bad release
   aborts with live untouched. Rollback = revert + push.
   (`bundle.tf`, `app/switch.sh`, ADR-0015)
 - **App-only pushes ship via `deploy-app`.** When infra is unchanged
   (`deploy-prod` skipped counts as satisfied; failed still blocks),
   the bundle uploads and `switch.sh deploy` runs over SSM — including
   from a cold edge (Caddy started first when missing) so a dead host
   recovers without replacement.
   (`.github/workflows/ci.yml`, `app/switch.sh`)
- **Cattle hosts.** Any `user_data` change replaces the instance
  (`user_data_replace_on_change`); EIP and data volume survive. The
  zero-downtime promise above covers app deploys only: a host replacement
  is a planned-maintenance event with minutes of downtime while the new
  box boots and the EIP swings (single host, single data disk — there is
  no second box to fail over to). A failed smoke test dumps the boot log
  via SSM into the `deploy-prod` job log.
  (ADR-0008)

## Serve

- **Phone-friendly HTTPS opencode.** Caddy terminates TLS (Let's Encrypt
  over `nip.io`) and proxies to `opencode web` on localhost; passwordless
  GitHub SSO (oauth2-proxy, single-user allowlist) is the human gate while
   the SSM-backed backend password stays machine-only (Caddy-injected),
   `302`-to-`/oauth2/*` gate, unauthenticated `/ping` for edge liveness
   plus public `/ready` (200 `"ready"` only while a backend color
   answers; bodies masked so the UI never leaks past SSO) as the
   readiness gate for deploys and uptime probing. The edge sends
   security headers (HSTS on real domains, nosniff, DENY/frame-ancestors,
   no-referrer, no Server banner), caps request bodies at 10MB, and all
   services run under memory/PID ceilings with dropped caps and
   no-new-privileges where safe.
   (`app/`, ADR-0001, ADR-0005, ADR-0014, ADR-0015)
- **Persistent state.** 10 GB encrypted EBS at `/var/lib/docker`:
  sessions, images, workspace, and certs survive replacement. Only a
  full destroy wipes it. (ADR-0008)
- **Agent git identity.** The agent commits/pushes as the operator:
  identity in vars, PAT in SSM, applied by an idempotent boot helper
  (10-min wait + verify) and re-applied on every app restart.
  (`modules/compute/user_data.sh`, ADR-0010)

## Watch

- **Intrusion alerting.** SSO-deny 403 bursts and backend 401 bursts
  (≥20/5 min each, plus a fast ≥10/1 min 401 twin) and sshd failures
  (≥3/5 min) ship to CloudWatch and page via SNS email (topic encrypted
  with the AWS-managed SNS key). Backend 5xx bursts (≥10/5 min) and
  sustained host CPU (>80% for 15 min) page too.
  (`modules/monitoring`, ADR-0006, ADR-0014)
- **Uptime probe.** Route 53 hits `/ready` every 30s, pages after 3
  failures — full chain (edge + backend), outside the login-failure
  metric. (`modules/monitoring`,
  ADR-0009, ADR-0015)
- **Audit trail.** Every apply stamps the commit SHA as `DeployedRef`
  (instance + disk) and `deployed_version`; plans are kept as 30-day
  artifacts. (`outputs.tf`) A single-region CloudTrail records account
  management events to a dedicated audit bucket (validated log files),
  and VPC Flow Logs ship to CloudWatch (30d) — post-incident forensics
  for API + network activity. State, bundle, and audit buckets enforce
  TLS-only access, keep access logs (90d), and expire noncurrent
  versions. (ADR-0017)

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
- **SSM-first access, IMDSv2-only host.** Port 22 opens only when
  `ssh_public_key` is set (paired with an explicit `/32`); default and
  SSM-only deploys expose no SSH ingress. The opt-in pair arrives via
  pipeline config, never git: public key in the `SSH_PUBLIC_KEY` variable,
  deployer `/32` in the `ALLOWED_SSH_CIDR` secret (masked in logs). EC2 metadata requires IMDSv2
  session tokens (hop limit 1). (ADR-0016)
- **Supply-chain hygiene.** SHA-pinned actions, Dependabot (21-day
  cooldown) for actions/terraform/compose-image pins, `tag@digest`
  images (including the Moto mock), and a pinned + checksummed compose
  fallback at boot that fails loud on mismatch. (ADR-0003)
- **Local testability.** Moto mock (`make local-up/plan-local/apply-local`,
  no credentials) plus `make test-boot` (compose chain with dummy env,
  dummy OAuth values — proves SSO wiring, not the GitHub round-trip).
  Moto catches config errors, never real-AWS behavior.

## Out of scope

- Multi-region, HA, staging environments.
- SSH-first access (SSM preferred; keys optional and empty by default).
- Manual deploys, laptop backends, long-lived AWS keys.
