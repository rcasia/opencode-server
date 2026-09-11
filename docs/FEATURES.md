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
- **Zero-downtime app deploys.** `app/` ships as a versioned S3 bundle;
  backend colors (`opencode-blue`/`opencode-green`, one live) switch via
  `switch.sh` over SSM: the idle color starts, must answer authed `GET /`
  through Caddy, and only then does the live color stop.
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
  SSM-backed backend password stays machine-only.
- **Provider API credentials.** Provider API keys are operator-created
  SSM SecureStrings. Terraform stores only parameter names. The instance
  role can read only the configured provider parameters; boot fetches them
  with shell tracing disabled into `/opt/opencode/app.env` (0600), and
  OpenCode consumes them through `{env:...}` in the managed config.
  Empty/unset parameter names leave that provider without credentials.
  Rotation is runtime-only: update the SecureString and use the existing
  app restart/switch path; no key is written to git or Terraform state.
- **Persistent state.** 10 GB encrypted EBS at `/var/lib/docker`:
  sessions, images, workspace, and certs survive replacement.
- **Agent git identity.** The agent commits/pushes as the operator:
  identity in vars, PAT in SSM, applied by an idempotent boot helper.
  The pinned backend image ships without git, so each backend installs
  it at container start (before the sandbox applies); without it the
  boot helper warns and agent git stays unavailable.
- **Sandboxed backend.** Both backend colors run `opencode web` under
  `nono` (Landlock) with the checked-in `app/nono-profile.json`:
  workspace + port 4096 + provider/GitHub egress allowed; IMDS,
  credential paths, and `docker.sock` denied. The pinned nono RPM rides
  the S3 bundle (CI verifies SHA, boot installs from disk). Agent
  container builds move out of the sandbox. Rationale: ADR-0020, ADR-0025.

## Watch

- **Intrusion alerting.** SSO-deny and backend authentication bursts,
  sshd failures, backend 5xx bursts, and sustained host CPU can page via
  CloudWatch/SNS.
- **Host health.** Data-disk use above 80% and memory above 90% (15 min)
  page via the same topic. Growth is bounded by construction: container
  logs capped at the daemon (10 MB x3), Caddy access log rotated
  (10 MB x3), unused images pruned weekly (never volumes — state
  survives). Rationale: ADR-0019.
- **Uptime probe.** Route 53 hits `/ready` every 30s and pages after
  repeated failures.
- **Audit trail.** Every apply stamps the commit SHA as `DeployedRef`;
  plans are kept as 30-day artifacts. CloudTrail and VPC Flow Logs provide
  post-incident API and network visibility.

## Trust

- **Pipeline-owned everything.** The deploy role, OIDC provider, and
  policy shards live in `bootstrap/` and are applied by the `bootstrap` CI
  job.
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
  pins, `tag@digest` images, and a pinned + checksummed compose fallback.
- **Local testability.** Moto mock plus `make test-boot` with dummy env
  values. The boot test validates provider env/config wiring without real
  provider credentials.

## Out of scope

- Multi-region, HA, staging environments.
- SSH-first access.
- Manual deploys, laptop backends, long-lived AWS keys.
