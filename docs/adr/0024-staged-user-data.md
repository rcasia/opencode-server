# ADR-0024: Staged user_data (bootstrap/app/monitoring)

## Status

Accepted

## Date

2026-09-11

## Context

`modules/compute/user_data.sh` was one 200-line blob rendered by
`templatefile` with `user_data_replace_on_change = true`: ANY edit —
even a monitoring threshold — replaced the host on next apply, with
EIP/volume reattach risk and minutes of downtime (#24). Meanwhile
`deploy-app` already proved app changes can converge over SSM without
Terraform.

## Decision

Three stages, split by replacement blast radius:

- **Bootstrap** (`modules/compute/user_data.sh`, still templated):
  disk attach/format/mount, docker install + log caps, AWS CLI,
  compose plugin, bundle fetch, `stage.env` + `provider-map.sh`
  render, `/usr/local/bin` wrappers, then runs the stages in boot
  order. ONLY this file (or a Terraform var it renders) forces
  replacement.
- **App** (`app/host/app.sh`, static, bundle-shipped): secrets
  refresh from SSM, `compose up`, git setup, colors service. Modes:
  `boot` (first up + live-color), `refresh` (secrets + git-setup),
  `secrets` / `git-setup` (surgical re-runs). `deploy-app` runs
  `secrets`, then `switch.sh deploy`, then `git-setup` — the new
  containers read the refreshed `app.env` at start and git config
  lands on the new live color.
- **Monitoring** (`app/host/monitoring.sh`, static, bundle-shipped):
  rsyslog, CloudWatch agent config, weekly image-prune timer.
  Idempotent; re-runs over SSM.

Stage scripts read non-secret config from `/opt/opencode/stage.env`
(SSM parameter NAMES, `%q`-escaped at boot; single quotes in values
unsupported). Secret VALUES come only from SSM at runtime. Wrappers
at the old `/usr/local/bin` paths keep `docs/credentials-rotation.md`
working unchanged.

Consequences: the `user_data` blob still changes when a TEMPLATE VAR
changes (EC2 mechanics — one blob), so Terraform-var edits still
replace; only stage SCRIPT edits ship replacement-free. `switch.sh
deploy` and `test-boot` are untouched.

## Related Decisions

- ADR-0007 (compose deployment), ADR-0008 (data volume),
  ADR-0011/0015 (bundle + blue-green), ADR-0019 (prune/CW agent),
  ADR-0004 (secrets discipline).
