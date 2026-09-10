# ADR-0001: Caddy as TLS Reverse Proxy for opencode Web

## Status

Accepted

## Date

2026-09-10

## Context

`opencode web` runs on the EC2 coding server and must be reachable from a
smartphone browser. Per the [opencode web docs](https://opencode.ai/docs/web/)
and [server docs](https://opencode.ai/docs/server/), the built-in protection
is HTTP basic auth via `OPENCODE_SERVER_PASSWORD` — there is **no built-in
TLS**. Serving basic auth over plain HTTP would leak the password to anyone
on the path, and phone IPs rotate (cellular), so IP-allowlisting the opencode
port is impractical.

Repo forces (see `AGENTS.md`): cheap by design (single `t3.micro`, no extra
paid infra), SSM preferred over open ports, least-privilege IAM, pipeline-only
deploys.

## Decision Drivers

- **Must encrypt in transit** — basic-auth credentials must never cross the
  network in cleartext.
- **Must work from a phone** — public HTTPS URL, no cert warnings, no extra
  apps or VPN clients.
- **Should add zero recurring cost** — no ALB (~$16/mo), no extra services.
- **Should minimize moving parts** — certificate issuance and renewal must
  not become a maintenance burden.

## Considered Options

### Option 1: Caddy reverse proxy on the instance

Caddy listens on 80/443, terminates TLS, and forwards to `opencode web`
bound to `127.0.0.1`. Certificates come from Let's Encrypt automatically
(HTTP-01, port 80) and renew themselves. Config is ~3 lines.

- **Pros**: automatic issuance + renewal, single static binary, no extra AWS
  resources, opencode port never exposed, phone gets a normal `https://` URL.
- **Cons**: needs a user-owned domain with an A record to the EIP (manual DNS
  step); TLS termination shares fate with the single instance (accepted —
  the whole server is already a single instance by design).

### Option 2: nginx + certbot

Same topology as Caddy, different software.

- **Pros**: team-familiar, huge community.
- **Cons**: manual issuance plus a renewal cron job to own and monitor —
  exactly the maintenance burden the drivers reject.

### Option 3: Tailscale private mesh

No public ports; phone uses the Tailscale app.

- **Pros**: nothing publicly exposed, WireGuard encryption, no domain needed.
- **Cons**: requires a Tailscale account plus an auth-key bootstrap secret,
  and a client app on the phone — worse phone UX, more secrets to manage.

### Option 4: Cloudflare Tunnel (`cloudflared`)

Outbound tunnel to Cloudflare; stable public hostname with Cloudflare TLS
and optional Access (SSO) login.

- **Pros**: no inbound SG rules at all, strong auth options.
- **Cons**: requires a Cloudflare account plus a tunnel-token secret, and an
  external dependency for every request — heavier than the problem warrants.

### Option 5: Direct public opencode port + password (rejected)

Fastest to build: open 4096 to the world with only basic auth.

- **Cons**: credentials in cleartext without TLS — fails the must-have.
  Rejected outright.

## Decision

We will run **Caddy on the instance as a TLS-terminating reverse proxy**
in front of `opencode web` bound to localhost, with the server password
supplied from an SSM SecureString parameter. Security group opens 80/443 to
the world (required for Let's Encrypt and roaming phones) and keeps SSH on
the existing `/32`; the opencode port gets **no** inbound rule.

## Rationale

Caddy is the only option that satisfies all four drivers at once: real TLS
with zero certificate maintenance, a normal phone-friendly HTTPS URL, no new
AWS resources or accounts, and a config small enough to live in `user_data`.

## Consequences

### Positive

- Phone access over standard HTTPS with opencode's basic-auth login.
- No certificate chores: issuance and renewal are Caddy's problem.
- No added cost: one binary on the existing instance.
- opencode never listens on a public interface, even if Caddy is stopped.

### Negative

- Requires a user-owned domain + A record pointing at the EIP (one-time
  manual step; documented in `README.md`).
- Port 80/443 open to `0.0.0.0/0` — intentional and required, mitigated by
  TLS + password + localhost-only backend.
- `user_data` changes replace the instance; the EIP (and therefore DNS)
  survives replacement.

### Risks

- If the domain's DNS doesn't resolve to the instance, Let's Encrypt
  issuance fails and Caddy serves nothing — mitigation: README lists the DNS
  check (`dig +short <domain>` == EIP) before expecting the site to load.

## Implementation Notes

- `modules/compute/user_data.sh`: install Caddy (COPR `@caddy/caddy`),
  write `Caddyfile` (`<domain> { reverse_proxy 127.0.0.1:4096 }`),
  `opencode-web.service` (`opencode web --hostname 127.0.0.1 --port 4096`,
  `OPENCODE_SERVER_PASSWORD` from SSM via `ExecStartPre`).
- Least-privilege IAM: instance role gets `ssm:GetParameter` on the one
  password parameter ARN only.
- New vars: `domain_name` (empty = skip Caddy config, Caddy installs but
  stays unconfigured), `opencode_password_parameter`
  (default `/opencode/server-password`).
- Manual steps for the operator: `aws ssm put-parameter --type SecureString`
  for the password; A record `<domain> -> <EIP>`.

## Related Decisions

- (none yet)

## References

- [opencode Web docs](https://opencode.ai/docs/web/)
- [opencode Server docs](https://opencode.ai/docs/server/)
- [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https)
