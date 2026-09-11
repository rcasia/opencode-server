# ADR-0028: Per-service env files instead of a shared app.env

## Status

Accepted

## Context

The stack previously wrote a single `app.env` file — shared by all four
services (`caddy`, `oauth2-proxy`, `opencode-blue`, `opencode-green`) via
`env_file: - app.env`. That file combined three classes of secret in one
place:

- Caddy-only: `DOMAIN`, `BASIC_AUTH`
- OAuth2-proxy-only: `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET`,
  `OAUTH2_PROXY_COOKIE_SECRET`, `OAUTH2_PROXY_GITHUB_USERS`,
  `OAUTH2_PROXY_REDIRECT_URL`
- opencode-only: `OPENCODE_SERVER_PASSWORD`, provider API keys
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …)

As a result every service received every secret, including provider API keys
inside the Caddy edge container and OAuth client secrets inside the opencode
backend containers. This violates least-privilege: a compromised Caddy process
(or a container escape) could read provider credentials it has no reason to hold.

## Decision Drivers

- **Must enforce least-privilege secret delivery**: each service receives only
  the env vars it needs to function.
- **Must remain atomically consistent**: writes are tmp-file + chmod 600 + mv,
  same pattern used by the existing single-file approach.
- **Should keep `refresh_secrets` readable**: group variables by service in the
  script, mirroring the three-file split.
- **Should make isolation verifiable**: `test-boot` can assert that caddy does
  NOT see provider API keys.

## Considered Options

### Option 1: Per-service env files (three files)

Write `caddy.env`, `oauth2.env`, and `opencode.env` separately; point each
service's `env_file:` at its own file.

- **Pros**: Enforces least privilege at the Docker daemon layer — no env var
  crosses a service boundary; isolation is auditable in `compose.yaml`;
  `test-boot` can assert absence; no runtime logic needed.
- **Cons**: Three files to keep consistent; `refresh_secrets` is slightly
  longer; `switch.sh` guard list grows from one file to three.

### Option 2: Keep a single `app.env`, use Docker secrets

Switch to Docker Swarm secrets or `configs` for per-service delivery.

- **Pros**: Native Docker isolation primitive.
- **Cons**: Requires Swarm mode or secrets plugin; incompatible with the
  current compose-only deployment model (ADR-0007); high migration cost for
  a marginal gain over option 1.

### Option 3: Keep shared `app.env`, accept the current exposure

No change.

- **Pros**: Simplest.
- **Cons**: Provider API keys live in Caddy and oauth2-proxy for no reason;
  violates least-privilege; fails a security review.

## Decision

We will adopt **Option 1**: split `app.env` into three per-service files
(`caddy.env`, `oauth2.env`, `opencode.env`), each written atomically by
`refresh_secrets` with `chmod 600` and `mv`.

## Rationale

Option 1 eliminates the cross-service secret bleed at the cheapest possible
cost: three `mktemp`/`mv` calls instead of one, and three `env_file:` entries
in `compose.yaml`. It needs no new infrastructure and is compatible with the
existing compose-only model. The isolation can be machine-verified in
`test-boot` (assert absence of `ANTHROPIC_API_KEY` from the caddy container),
which closes the feedback loop automatically on every CI run.

## Consequences

### Positive

- Provider API keys are no longer present in the Caddy or oauth2-proxy
  container environments.
- GitHub OAuth secrets are no longer present in the opencode backend.
- Isolation is expressed declaratively in `compose.yaml` and verified by
  `test-boot`.
- Secret rotation scope is clearer: rotating a provider key only requires
  updating `opencode.env`, not touching `caddy.env` or `oauth2.env`.

### Negative

- `switch.sh` guard check grows from `[ -f app.env ]` to three `[ -f ... ]`
  conditions — minor readability cost.
- `refresh_secrets` manages three temp files; the cleanup trap must rm all
  three. Mitigated by grouping the variables clearly by section comment.
- Existing hosts carry `app.env` after the first `refresh_secrets` run; the
  old file is no longer read but is not automatically deleted. Operators can
  `rm /opt/opencode/app.env` after the first post-deploy secret refresh.

## Implementation Notes

- `app/compose.yaml`: `caddy` → `caddy.env`, `opencode-blue`/`opencode-green`
  → `opencode.env`, `oauth2-proxy` → `oauth2.env`.
- `app/host/app.sh` (`refresh_secrets`): three `mktemp` calls, three atomic
  `mv` destinations; `fetch_provider` appends to `$TMP_OPENCODE`.
- `app/switch.sh` (`cmd_deploy`): guard becomes
  `[ -f caddy.env ] && [ -f oauth2.env ] && [ -f opencode.env ]`; `DOMAIN`
  sourced from `caddy.env`.
- `app/app.env.example` deleted; replaced by `caddy.env.example`,
  `oauth2.env.example`, `opencode.env.example`.
- `scripts/test-boot.sh`: writes three files instead of one; trap cleans
  all three; assertions check isolation (caddy must not see provider keys).

## Related Decisions

- [ADR-0004](0004-ssm-password.md) — SSM as the secret store; this ADR
  refines the delivery path on the instance side.
- [ADR-0007](0007-compose-deployment.md) — compose-only model constrains the
  solution space (no Swarm secrets).
- [ADR-0018](0018-provider-api-keys.md) — provider API key lifecycle; this
  ADR tightens their runtime exposure.

## References

- GitHub issue #40: Split `app.env` into per-service env files
- Docker Compose `env_file` reference: https://docs.docker.com/compose/compose-file/05-services/#env_file
