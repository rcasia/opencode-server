# ADR-0015: Blue-Green Backends with a Public /ready Gate

## Status

Accepted

## Date

2026-09-11

## Context

ADR-0011 removed host replacement from app deploys, but the rollout itself
— `docker compose pull && docker compose up -d` over SSM — still stops the
only backend before the new one answers. Every app deploy therefore has a
seconds-long window of 502s, twice confirmed against the edge. Two more
gaps surfaced while fixing it:

- Nothing proves the new backend serves before it takes traffic. `/ping`
  answers from Caddy unconditionally, so neither the pipeline nor the
  Route53 probe can tell "edge up, app down" apart from healthy.
- App-only pushes never uploaded the bundle: `deploy-prod` (the only
  uploader) is skipped when infra is unchanged, so `deploy-app` restarted
  the *previous* bundle. The pipeline worked only because most app changes
  rode along with infra changes.

## Decision Drivers

- **Must switch traffic with zero failed requests** — readiness decides
  the switch, not hope.
- **Must keep a bad release off traffic** — if the new backend never
  answers, the live one keeps serving and the deploy fails red.
- **Should stay on one cheap host** — no second box, no EIP flip, no NAT.
- **Should keep rollback = revert + push.**

## Considered Options

### Option 1: Blue-green colors behind a stable edge, /ready-gated (chosen)

Two identical backend services (`opencode-blue`, `opencode-green`), one
live at a time. Caddy lists both upstreams with `lb_policy first` plus
active (`health_uri /` with the machine-only Basic auth) and passive
(`fail_duration`) health checks, so stopping the live color fails traffic
over to the ready one with retries. `app/switch.sh` (shipped in the S3
bundle, run over SSM) recreates the idle color, polls it *through Caddy*
until authed `GET /` answers 2xx, reloads Caddy only when the Caddyfile
actually changed, then stops the live color. Public `/ready` (no SSO,
body masked to `ready`/`not ready` via `handle_response`) is the gate the
pipeline and Route53 poll.

- **Pros**: zero failed requests on backend + Caddyfile deploys; bad
  releases abort with live untouched; rollback stays revert + push; one
  host, cents of infra (brief overlap only).
- **Cons**: two services to keep in sync; brief dual-run shares the
  workspace volume; reboot starts both (needs a reconciler); Caddy held at
  one extra config block.

### Option 2: Retry-cover on a single backend (rejected)

Keep one `opencode` service and set `lb_try_duration` long enough to ride
out the stop/start gap. No switch, no extra service.

- **Pros**: smallest diff.
- **Cons**: no readiness decision — a bad image takes traffic and the gap
  becomes an outage; every deploy holds user requests for the full backend
  boot; still fails the "bad release stays off traffic" driver. Hope is
  not a gate.

### Option 3: Second host + EIP flip (rejected)

Same as ADR-0011's rejected blue-green: doubles steady cost, splits the
data disk across writers, and buys nothing over Option 1 for a single
tenant who deploys a few times a month.

## Decision

We will ship **app changes via blue-green backend colors with a
/ready-gated switch**, keeping Caddy as the never-recreated edge
(`caddy reload` on Caddyfile changes only).

## Rationale

It is the only option that meets both must-drivers on one host: the
readiness gate makes the switch a decision (with a safe abort), and the
stable edge with health-checked failover turns the switch itself into
retries instead of failures. Everything else — bundle, SSM, smoke tests,
concurrency, fail-open gates — is reused unchanged.

## Consequences

### Positive

- Backend + Caddyfile deploys: no failed requests; sessions and workspace
  survive on the shared disk; `test-boot` rehearses the exact switch
  locally and fails on any sampled failure.
- Failed releases never take traffic (live keeps serving, CI goes red,
  Route53 keeps paging on the old color if it was already broken).
- Route53 on `/ready` now pages on app failure, not just edge failure.

### Negative

- **Caddy binary updates still restart the edge** (seconds, ~monthly
  Dependabot bumps): one container must hold :80/:443, so there is no
  overlap for the edge itself. `switch.sh` skips the reload-then-restart
  double touch when it detects the image change.
- **oauth2-proxy stays single** (`forward_auth` takes one upstream): its
  own rare image bumps restart it with a seconds-long SSO blip.
- **Agent websocket sessions on the live color drop at the switch**
  (HTTP stays clean; clients reconnect). `stop_grace_period: 30s` plus
  `stream_close_delay 5m` cushion reloads, not the color stop.
- Brief overlap runs two backends (~2x backend RAM for a minute) sharing
  the workspace volume — one deploy at a time (`prod-deploy`
  concurrency) keeps this safe.
- Reboots start both colors (`restart: always`); a oneshot systemd unit
  stops the non-live one from `.live-color` on every boot.

## Implementation Notes

- `app/compose.yaml`: `opencode-blue` + `opencode-green` (identical;
  keep in sync), shared volumes, `stop_grace_period: 30s`; Caddy
  `depends_on` both. Never bare `up` on the host — name services.
- `app/Caddyfile`: dual upstreams + `first` + health checks on `/` and
  the main handle; public `handle /ready` (rewrite to `/`, mask bodies).
- `app/switch.sh` (`deploy`/`reconcile`): in the bundle, fetched at boot,
  run by `deploy-app` over SSM after uploading. First run migrates the
  pre-blue-green `opencode` container (stop only after blue answers).
- `modules/compute/user_data.sh`: fetches 3 bundle files, boots
  `caddy oauth2-proxy opencode-blue` explicitly, writes `.live-color`,
  installs `opencode-colors.service`; git-setup targets the live color.
- `deploy-app` uploads the bundle first (fixes the stale-bundle gap),
  runs `switch.sh deploy`, then asserts `/ready` body `ready` + SSO gate.
- Rollback is still revert + push (S3 versioned). Roll-forward of a
  half-switched host converges via `.live-color` + reconcile.

## Related Decisions

- ADR-0011 (superseded rollout mechanism; the versioned S3 bundle stands),
  ADR-0002 (pipeline this extends), ADR-0007 (compose stack),
  ADR-0008 (state survives on the shared disk),
  ADR-0009 (probe moves from `/ping` to `/ready`),
  ADR-0014 (SSO gate untouched; `/ready` bypasses it by design)

## References

- [Caddy reverse_proxy: load balancing, health checks, handle_response](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
