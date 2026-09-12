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
  `deploy-app` (app-file changes only).
- **Real prompt deployment gate.** Host-replacing and app-only deploys create
  an isolated session on the live backend, require `prompt_async` to return
  204, and wait up to 90 seconds for a completed provider response. Failures
  retain bounded, secret-free SSM output as a CI artifact. The same check is
  manually runnable through `workflow_dispatch`; public TLS, readiness, and
  SSO redirects remain separate edge checks because GitHub OAuth has no safe
  unattended browser session. Rationale: issue #65.
- **Zero-downtime app deploys.** `app/` ships as a per-commit S3 bundle
  (`app/<sha>/`); backend colors (`opencode-blue`/`opencode-green`, one live) switch via
  `switch.sh` over SSM: the idle color starts, must answer authed `GET /`
  through Caddy, and only then does the live color stop. A boot always
  runs exactly the commit Terraform applied (no fixed keys, no
  state/artifact drift); `deploy-app` runs on every app change the
  deploy did not already ship via replacement. Rationale: ADR-0015, issue #45.
- **Constrained session recovery.** Deploys drain first: `switch.sh`
  polls `GET /session/status` on the live color and delays its stop
  while a run is active (bounded ~5 min, then proceeds). After the
  switch (and at boot via `reconcile`), it probes the live color for
  sessions interrupted by the deploy (dangling user message + idle
  status + updated near the deploy), marks them
  `[interrupted-by-deploy]`, and auto-retries via `prompt_async` only
  when `GET /session/:id/diff` is empty; sessions with file changes
  stay marked for human retry (revert/fork first). Rationale: ADR-0022.
- **Managed OpenCode configuration.** `app/opencode.json` is part of the
  application bundle and is mounted read-only as the global OpenCode config
  inside both backend colors. It contains model defaults and provider
  configuration; provider API keys are referenced only through
  `{env:VAR}` substitutions and never committed. Precedence: the managed
  file is the global default and a project-level `opencode.json` in the
  workspace overrides it per key (ADR-0025).
 - **App-only pushes ship via `deploy-app`.** When infra is unchanged,
   the bundle uploads and `switch.sh deploy` runs over SSM — including
   from a cold edge.
- **Cattle hosts, staged boot.** `user_data` is a thin bootstrap (disk,
  docker, toolchain); the app (`app/host/app.sh`) and monitoring
  (`app/host/monitoring.sh`) stages ship via the bundle and re-run over
  SSM. Only bootstrap or Terraform-var changes replace the instance;
  EIP and data volume survive. App deploys do not replace the host.

## Serve

- **Phone-friendly HTTPS opencode.** Caddy terminates TLS and proxies to
  `opencode web`; passwordless GitHub SSO is the human gate while the
  SSM-backed backend password stays machine-only. SSO sessions re-validate
  with GitHub hourly (`cookie_refresh 1h`) and expire after 24h, so a
  revoked grant or rotated client secret ends sessions within the hour.
- **Provider API credentials.** Provider API keys are operator-created
  SSM SecureStrings. Terraform stores only parameter names. The instance
  role can read only the configured provider parameters; boot fetches them
  with shell tracing disabled into `/opt/opencode/opencode.env` (0600), and
  OpenCode consumes them through `{env:...}` in the managed config.
  Empty/unset parameter names leave that provider without credentials.
  Rotation is runtime-only: update the SecureString and use the existing
  app restart/switch path; no key is written to git or Terraform state.
- **Per-service secret isolation.** Secrets are split into three 0600 env
  files written atomically by `refresh_secrets`: `caddy.env` (DOMAIN,
  BASIC_AUTH), `oauth2.env` (GitHub OAuth client/cookie secrets), and
  `opencode.env` (backend password + provider API keys). Each compose
  service mounts only its own file, so provider keys never reach the Caddy
  or oauth2-proxy containers (ADR-0028).
- **Persistent state.** 10 GB encrypted EBS at `/var/lib/docker`:
  sessions, images, workspace, and certs survive replacement.
- **Agent git identity.** The agent commits/pushes as the operator:
  identity in vars, PAT in SSM, applied by an idempotent boot helper.
  The pinned backend image ships without git, so each backend installs
  it at container start (before the sandbox applies); the boot helper
  waits for it and a git failure only warns — it never fails boot.
- **Sandboxed backend.** Both backend colors run `opencode web` under
  `nono` (Landlock) with the checked-in `app/nono-profile.json`:
   workspace + port 4096 + provider/GitHub/opencode.ai egress allowed; IMDS,
  credential paths, and `docker.sock` denied. The pinned nono musl
  tarball rides the S3 bundle (CI verifies SHA, boot installs from
  disk; static binary serves host and container — no distro RPM).
  Agent container builds move out of the sandbox.
  Rationale: ADR-0020, ADR-0025, ADR-0027.
- **Hardened backend containers.** Both backend colors use `cap_drop: [ALL]`
  + `cap_add: [SYS_PTRACE]` (nono requirement) and `no-new-privileges:true`,
  matching the posture of caddy and oauth2-proxy in the same stack. `docker.sock`
  is never mounted; re-adding it requires an explicit ADR (credential-theft
  path documented in ADR-0026). Rationale: ADR-0026.
- **Explicit opencode.json permissions.** The managed `app/opencode.json` grants
  file tools (`read`, `edit`, `glob`, `grep`, `list`) and subagent tools
  (`task`, `todowrite`) as `allow`; shell (`bash`), network reads (`webfetch`,
  `websearch`), and cross-repo access (`external_directory`) require operator
  confirmation (`ask`). Any future tool not listed defaults to `ask` rather
  than auto-allowing. Rationale: ADR-0026.

## Watch

- **Intrusion alerting.** SSO-deny and backend authentication bursts,
  sshd failures, backend 5xx bursts, and sustained host CPU can page via
  CloudWatch/SNS. An unset `ALERT_EMAIL` warns in deploy-prod but never
  blocks (alarms page nobody until the SNS email is confirmed). Delivery
  is verified by forced alarm state + the topic's Delivered metric (the
  email protocol exposes no per-message status API); no
  success-after-probing correlation by design (issue #13).
- **Host health.** Data-disk use above 80% and memory above 90% (15 min)
  page via the same topic — metrics carry the InstanceId dimension and
  missing data pages (a dead agent must not hide). System-check failure
  auto-recovers to healthy hardware, instance-check failure reboots.
  Growth is bounded by construction: container
  logs capped at the daemon (10 MB x3), Caddy access log rotated
  (10 MB x3), unused images pruned weekly (never volumes — state
  survives). Rationale: ADR-0019.
- **Uptime probe.** Route 53 hits `/ready` every 30s and pages after
  repeated failures.
- **Audit trail.** Every apply stamps the commit SHA as `DeployedRef`;
  plans are kept as 30-day artifacts. CloudTrail and VPC Flow Logs provide
  post-incident API and network visibility. Shipped off-host: Caddy access
  log, `/var/log/secure`, cloud-init output. Deliberately NOT shipped:
  agent container stdout (prompts, code, echoed secrets stay local under
  the 10 MB x3 daemon cap) — rationale: issue #55. SSM shell sessions
  stream to a dedicated 90-day log group (20-min idle timeout, runAs
  ssm-user) — rationale: issue #54.

## Trust

- **Pipeline-owned everything.** The deploy role, OIDC provider, and
  policy shards live in `bootstrap/` and are applied by the `bootstrap` CI
  job. The role's `SendCommand` reaches only instances tagged for this
  stack (Project/Environment tag condition); command reads stay wildcard
  (they authorize on no instance ARN). Rationale: issue #41.
- **Pipeline-only ops, no reads either.** No laptop plans, applies,
  backends, outputs, shells, or console edits.
- **Secrets discipline.** Secrets live in SSM SecureStrings or GitHub
  secrets, never in git/state/logs. `detect-secrets` gates commits.
  Provider keys extend this rule: Terraform receives only SSM parameter
  names and the instance role receives only the corresponding
  `ssm:GetParameter` permissions.
- **Public-repo defaults.** Committed `prod.tfvars` carries no operator
  PII: example domain, empty SSO/git identity (fail closed). Real values
  arrive via Actions secrets (`TF_VAR_` wins). The OIDC deploy subject
  keeps its numeric-ID form as a documented personal-repo exception —
  the slug form does not match and locks the pipeline out.

## Sustain

- **Cheap by design.** Single AZ public subnet, no NAT, `t3.small`, EIP
  attached, with low-cost probes and encrypted persistent storage.
  The data disk gets daily DLM snapshots (keep 7, cents/month);
  restores follow `docs/restore-data-volume.md`. Rationale: ADR-0030.
- **Cost guardrail.** A monthly AWS cost budget (default $25,
  `monthly_budget_limit_usd`) pages the same SNS topic as the intrusion
  alarms on actual spend ≥100% and on forecasted spend ≥100%. Current
  burn ≈ $19–22/mo in eu-west-1: `t3.small` ≈ $15–17, root 30 GB gp3 ≈
  $2.4–2.7, data 10 GB gp3 ≈ $0.8–0.9, Route53 `/ready` probe ≈ $0.50,
  S3 (bundle/audit/logs) + CloudWatch logs cents. The $25 default covers
  that burn with headroom for price drift; lower it via the var if the
  burn drops. Rule (AGENTS.md 8): any change that adds recurring cost
  must be called out in the push — never silently grow the bill.
- **SSM-first access, IMDSv2-only host.** Port 22 opens only when an
  explicit /32 SSH configuration is supplied; otherwise use SSM.
- **Supply-chain hygiene.** SHA-pinned actions, Dependabot for dependency
  pins, `tag@digest` images, a pinned + checksummed compose fallback, a
  pinned + checksummed AWS CLI zip (floating upstream URL, hash recorded
  at bump time — mismatch fails boot closed), and coherent provider locks
  (root + bootstrap both on the v6 line). Rationale: issue #12.
- **Local testability.** Moto mock plus `make test-boot` with dummy env
  values. The boot test validates provider env/config wiring without real
  provider credentials.

## Out of scope

- Multi-region, HA, staging environments.
- SSH-first access.
- Manual deploys, laptop backends, long-lived AWS keys.
