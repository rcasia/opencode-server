# Security Policy

## Reporting a vulnerability

This is a personal infrastructure repo with a small operator base. If you
find a vulnerability, **do not open a public issue**. Report it privately
via the repo **Security tab → Advisories → Report a vulnerability**
(private vulnerability reporting), so it can be fixed before disclosure.
Include steps to reproduce and the commit SHA you tested against.

## What this repo protects

- **No live credentials in git.** Secrets live in AWS SSM SecureStrings
  or GitHub Actions secrets/variables only. Committed `prod.tfvars`
  holds placeholders that fail closed (example domain, empty SSO and
  git identity); the operator injects real values via `TF_VAR_`
  secrets. `detect-secrets` gates every commit.
- **Pipeline-only prod.** All AWS changes flow through the OIDC
  deploy role scoped to this repo, the `prod` environment, and
  `refs/heads/main`. Fork PRs cannot assume the deploy role and
  receive no secrets.
- **Least privilege by default.** SSH ingress is SSM-only unless an
  explicit `/32` is configured; EBS volumes are encrypted; the agent
  container faces mTLS/SSO gates, never the open internet.
- **Session audit.** SSM shell sessions stream to a dedicated CloudWatch
  log group (90-day retention) via a pipeline-owned Session document —
  interactive access leaves a command record, not just a session start.

## Supported versions

Only `main` is supported. Security fixes land on `main` and deploy
through the pipeline like any other change.
