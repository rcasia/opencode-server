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
- **Managed OpenCode configuration.** `app/opencode.json` is part of the
  application bundle and is mounted read-only as the global OpenCode config
  inside both backend colors. It contains model defaults and provider
  configuration; provider API keys are referenced only through
  `{env:VAR}` substitutions and never committed.
 - **App-only pushes ship via `deploy-app`.** When infra is unchanged,
   the bundle uploads and `switch.sh deploy` runs over SSM — including
   from a cold edge.
- **Cattle hosts.** Any `user_data` change replaces the instance;
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
