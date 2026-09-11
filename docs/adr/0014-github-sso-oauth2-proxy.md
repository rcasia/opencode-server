# ADR-0014: Passwordless GitHub SSO via oauth2-proxy

## Status

Accepted

## Date

2026-09-11

## Context

`opencode web` ships only HTTP basic auth (`OPENCODE_SERVER_PASSWORD`,
username `opencode`) with no built-in TLS (ADR-0001) and no SSO. The
operator logs in from a phone by typing a shared password — phishing- and
shoulder-surfing-prone, painful on mobile, and a single static secret
protecting an internet-facing coding agent. Issue #17 asks for human login
without typing a shared password, with GitHub as the IdP and a
single-user allowlist.

Constraint from opencode docs: unset `OPENCODE_SERVER_PASSWORD` = unsecured
server. So the backend password cannot go away — it stays as a
**machine-only** secret the human never types, and GitHub SSO becomes the
**human gate** (defense in depth, keeps ADR-0004).

## Decision Drivers

- **Must keep the backend password** — removing it leaves the server
  unsecured per opencode docs; the human gate must sit in front of it.
- **Must fit `t3.micro`/`t3.small` and cheap-by-design** — ~20 MB extra
  RAM max, no new AWS resources, no DB, no backups (ADR-0001 drivers).
- **Should be phone-friendly** — GitHub login page + persistent session
  cookie, standard HTTPS, no client certs or VPN apps.
- **Must keep secrets out of git/state/logs** — same discipline as
  ADR-0004 and issue #10 (`set +x`/`unset`, `0600` env file, narrow IAM).
- **Should keep alerting meaningful** — browsers stop seeing 401s after
  SSO, so the deny signal must move to the SSO layer (ADR-0006).

## Considered Options

### Option 1: Keycloak as IdP broker (rejected)

Full IAM suite (JVM + Postgres) on the same 1–2 GB box that already runs
Docker + Caddy + opencode + the CloudWatch agent — forces an instance bump
+ EBS growth + DB backups, breaking cheap-by-design. More secrets to own
(admin password, DB password, client secret) and more hardening (admin
console, realm config) for zero gain on a single-user box.

### Option 2: oauth2-proxy with GitHub provider, single-user allowlist (chosen)

`quay.io/oauth2-proxy/oauth2-proxy` (~20 MB Go binary) as a third compose
service with `--provider=github` + `--github-user=<operator>`; no published
ports, reachable only via Caddy `forward_auth`. Caddy serves `/oauth2/*`
directly (login/callback), gates everything else on `/oauth2/auth` with a
redirect to `sign_in` for logged-out browsers, and injects
`Authorization: Basic {$BASIC_AUTH}` (base64 of `opencode:<password>`,
precomputed at boot) to the backend.

- **Pros**: fits RAM, no AWS resources, GitHub is already the operator's
  IdP (no new account), session cookie is phone-friendly, backend password
  stays machine-only, rotation stays `put-parameter --overwrite` + restart.
- **Cons**: one more container to pin/dependabot; operator creates a GitHub
  OAuth App + two SSM secrets once; local `test-boot` uses dummy OAuth
  values (real IdP flow only provable in prod).

### Option 3: Keep the shared typed password (rejected)

Zero work, but keeps the exact risk issue #17 was filed to remove: a human
typed static secret as the sole gate, awkward on phones.

## Decision

We will put oauth2-proxy (GitHub provider, `--github-user` allowlist) in
front of `opencode web` via Caddy `forward_auth`, keep
`OPENCODE_SERVER_PASSWORD` as a machine-only backend secret injected by
Caddy, store the OAuth client secret + cookie secret in SSM SecureStrings
with instance-only reads, and alert on SSO-deny 403s alongside the kept
backend-401 signal.

## Rationale

It is the only option that removes the human-typed password without
removing the backend password, fits the existing box and cost envelope,
and reuses the proven SSM/env-file/IAM shape from ADR-0004 — with the
official Caddy `forward_auth` integration pattern, not a bespoke proxy.

## Consequences

### Positive

- No shared password typed by a human; GitHub login + session cookie,
  phone-friendly.
- Defense in depth: GitHub SSO (human gate) + backend basic auth
  (machine-only) + TLS.
- No new AWS resources; negligible RAM; rotation without Terraform runs.

### Negative

- One-time operator setup: GitHub OAuth App (callback
  `https://<domain>/oauth2/callback`), two SSM secrets, two public vars —
  documented in README; a missing value fails the SSO container loudly.
- `test-boot` proves wiring with dummies, not the GitHub round-trip
  (accepted: IdP flow is verified by a prod login after deploy).
- One more pinned image to maintain via Dependabot (mitigation: same
  `tag@digest` policy as ADR-0003).

## Implementation Notes

- `app/compose.yaml`: `oauth2-proxy` service
  (`quay.io/oauth2-proxy/oauth2-proxy:v7.15.4@sha256:b1b2…`), `expose`
  only, static `OAUTH2_PROXY_*` env, `env_file: app.env` for secrets/IDs.
- `app/Caddyfile`: `handle /oauth2/*` → `reverse_proxy oauth2-proxy:4180`;
  `handle` → `forward_auth …/oauth2/auth` (401 → `redir /oauth2/sign_in`)
  then `reverse_proxy opencode:4096` with
  `header_up Authorization "Basic {$BASIC_AUTH}"`.
- `variables.tf` → `modules/compute`: `github_oauth_client_id`,
  `github_oauth_user` (public), `github_oauth_secret_parameter`,
  `oauth_cookie_secret_parameter` (SSM names); instance role gains
  `ssm:GetParameter` on the two new ARNs only.
- `modules/compute/user_data.sh`: writes `OAUTH2_PROXY_CLIENT_ID`,
  `OAUTH2_PROXY_GITHUB_USERS`, `OAUTH2_PROXY_REDIRECT_URL` in clear and
  fetches the client secret + cookie secret plus derives `BASIC_AUTH`
  inside the existing `set +x`/`unset` block (`0600`).
- `modules/monitoring`: keep the 401 filter/alarm (backend signal), add a
  403 `oauth-deny` filter + alarm (SSO-gate signal); `/ping` stays
  unauthenticated.
- `scripts/test-boot.sh` + CI smoke tests: expect the 302 → `/oauth2/*`
  gate instead of 401 (401 still accepted during rollout).
- Operator manual steps (README): create the GitHub OAuth App, store the
  two SSM secrets (cookie secret: `openssl rand -base64 32 | tr -- '+/' '-_'`),
  set `github_oauth_client_id`/`github_oauth_user`, push (instance is
  cattle — `user_data` changes replace it).

## Related Decisions

- ADR-0001 (Caddy proxy; SSO is the human layer above TLS + backend auth)
- ADR-0004 (SSM password pattern reused for the two new secrets)
- ADR-0006 (alerting moves to the SSO layer) + ADR-0009 (`/ping` untouched)
- ADR-0007 (compose layout + `test-boot`) + ADR-0011 (bundle/rolling deploys)
- Issue #17 (feature), issue #10 (`set +x` discipline for the new secrets)

## References

- [oauth2-proxy Caddy integration](https://oauth2-proxy.github.io/oauth2-proxy/configuration/integrations/caddy)
- [oauth2-proxy GitHub provider](https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/github)
- [opencode Web authentication](https://opencode.ai/docs/web/#authentication)
