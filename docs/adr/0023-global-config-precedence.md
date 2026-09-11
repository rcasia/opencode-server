# ADR-0023: Managed global OpenCode config and merge precedence

## Status

Accepted

## Date

2026-09-11

## Context

`app/compose.yaml` mounts `opencode-config:/root/.config/opencode` but
nothing wrote to it: the global config started empty, drifted per boot,
and persisted only by accident on the EBS data disk. There was no repo
control over model defaults, permissions, `autoupdate`, or share policy
(#19). `app/opencode.json` is now the source of truth, shipped via the
S3 bundle and bind-mounted read-only at
`/root/.config/opencode/opencode.json` in both backend colors.

## Decision

The managed file is the **global** config: it sets host-wide defaults
(model, small_model, provider `{env:}` references, permission baseline,
`autoupdate: false`, `share: disabled`, compaction). OpenCode merges
config sources instead of replacing them (upstream precedence: remote <
global < `OPENCODE_CONFIG` < project `opencode.json` < `.opencode/`
dirs < inline < managed). A project-level `opencode.json` in the
workspace therefore overrides our global defaults per conflicting key,
which is the intended escape hatch — not a bug.

Consequences, stated plainly:

- Guardrails that must survive a hostile or sloppy project config do
  NOT belong in `app/opencode.json` (a project file can override them).
  True enforcement needs OS-level managed config (`/etc/opencode/`),
  which we deliberately do not use (single-tenant host, no untrusted
  projects).
- `share: disabled` and `permission: {"*": "allow"}` are defaults for
  our own sessions, not sandbox boundaries (see ADR-0020 for the real
  sandbox discussion).
- Rollback is revert + push: the bundle carries the config and
  `deploy-app` converges it without host replacement.

## Validation

`scripts/test-boot.sh` asserts `jq empty`, the `{env:}` provider
references, and the mount inside the backend container; the `app-test`
CI job runs it on every app/pipeline change.

## Related Decisions

- ADR-0007 (compose deployment), ADR-0011/0015 (bundle + blue-green),
  ADR-0018 (provider keys via `{env:}`), ADR-0020 (sandbox spike).
