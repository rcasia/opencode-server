# ADR-0023: nono Sandbox Pilot (vendored RPM + checked-in profile)

## Status

Accepted (implements #30; builds on the ADR-0020 adopt verdict)

## Date

2026-09-11

## Context

Issue #25 spiked kernel-enforced sandboxing for the `opencode` container
with `nono` (Landlock LSM). ADR-0020 recorded the verdict: **adopt a
pilot with `docker.sock` CUT** — agent docker builds stop working inside
the sandbox — with the profile checked into `app/`, shipped via the S3
bundle (#19 pattern), and the binary installed from a pinned,
checksummed RPM, never `curl | sh` at boot (ADR-0003).

Issue #30 is that pilot. Issue #31 (sandboxed `test-boot` assertions:
web + SSO + git + model call with dummy creds, plus negative probes for
IMDS / `~/.aws` / `docker.sock`) stays open; this pilot keeps the
existing `test-boot` suite green without claiming the sandbox proof.

## Decision

- **Pin nono `0.76.0`** (released 2026-09-09). SHA256 pins live in two
  places that `test-boot` cross-checks: `app/nono-version.json`
  (manifest) and `modules/compute/user_data.sh` (boot pins, same
  per-arch pattern as the compose fallback).
- **CI-fetch to S3, never curl-at-boot.** The `deploy-prod` job
  downloads both arch RPMs from the pinned GitHub Release URLs,
  verifies SHA256, and uploads to the versioned app bundle. Boot
  (`user_data.sh`) selects the RPM by `uname -m`, re-verifies the
  checksum from disk, and `dnf install`s it, then asserts
  `nono --version`. No RPM bytes in git; the reviewed diff is
  version + hashes.
- **Profile `app/nono-profile.json` v1.0.0**, validated with
  `nono profile validate`. It extends `default` (so `deny_credentials`
  and friends apply), allows the container workspace plus the opencode
  config/data/cache paths, grants `listen_port 4096`, filters egress
  through network profile `opencode` (provider APIs + GitHub; the
  proxy always denies IMDS/link-local), and adds an explicit
  `filesystem.deny` for `/var/run/docker.sock`.
- **Wrap the backend command** in `app/compose.yaml`:
  `nono run --profile /etc/nono/profile.json -- opencode web …`,
  with the host binary (`/usr/bin/nono` from the RPM) and the profile
  bind-mounted read-only. `SYS_PTRACE` is added back to the backends
  (nono's documented requirement for its seccomp network-proxy
  handoff inside Docker; it only lets nono's parent duplicate an fd
  from its own child).
- **`docker.sock` mounts removed** from both backend colors. Consequence
  as decided: the agent loses docker builds; container work moves
  outside the sandbox until a brokered path is proposed separately.
- **Profile-only pushes ship via `deploy-app`** (no replacement);
  the SSM switch step re-syncs the profile. **Binary bumps ride
  `user_data.sh`** and therefore replace the host (cattle rule);
  `deploy-app` deliberately does not fetch the RPM.

## Same-week audit exception (ADR-0003)

`0.76.0` is 2 days old at landing, inside the 21-day cooldown — taken
as an explicit same-day-style override with this audit, never by
default: release date checked (2026-09-09, `v0.76.0` tag on
`nolabs-ai/nono`); artifacts are immutable release files verified by
SHA256 at two independent points (CI fetch, boot install); no
latest-tracking installer touches any host. Routine bumps should
prefer releases older than 21 days; the manifest records the clock
start. Reviewers re-verify the SHAs against the upstream
`SHA256SUMS.txt` before merge.

## Accepted residual risks

- **Git PAT single-file grant.** `deny_credentials` blocks
  `~/.git-credentials`, but agent `git push` (issue #10) needs it, so
  the profile grants exactly that file via `read_file` +
  `bypass_protection`. The wrapped command pre-touches the file so the
  grant resolves at sandbox start. Token exposure to a tricked agent
  is unchanged from pre-pilot; a brokered git credential is future work.
- **Environment passthrough.** Provider keys and backend secrets stay
  in process env (opencode needs them there for `{env:…}`
  substitution). nono credential injection is future work, not this pilot.
- **Landlock parent-grant caveat.** The workdir grant (`/root`)
  overlaps deny-group paths; on Linux, Landlock is allow-list-first,
  so deny-under-allow is best-effort. Defense in depth comes from not
  mounting secrets into the container at all: no `~/.aws`, no
  `~/.ssh`, no `app.env` file, no socket — the only on-disk secret is
  the git-credentials file above. #31's negative probes will show
  exactly what holds.

## Profile versioning policy

- **Bump cadence:** manual, reviewed diffs (version + SHAs in
  `user_data.sh` and `app/nono-version.json` together; `test-boot`
  fails if they drift). Prefer releases past the 21-day cooldown;
  same-week takes need the explicit audit above.
- **Rollback:** profile-only revert ships via `deploy-app`
  (revert + push, no replacement). Binary revert rides
  `user_data.sh` and replaces the host. Both paths are the standard
  bundle rollback (revert + push).

## Consequences

### Positive

- Kernel-enforced boundary replaces prompt-enforced `permission: allow`
  as the real containment for file + network + IMDS.
- Pinned, checksummed, S3-vendored install keeps ADR-0003 intact.

### Negative

- Agent docker builds break (accepted, per ADR-0020).
- One more pinned binary stream to bump manually (no Dependabot
  ecosystem covers RPM pins).
- Host replacement on every binary bump (cattle rule).

## Related Decisions

- ADR-0020 (spike verdict this pilot implements; not superseded —
  design unchanged, this record adds implementation + policy)
- ADR-0003 (supply-chain hygiene the install path satisfies)
- ADR-0007 / ADR-0011 / ADR-0015 (bundle + blue-green the profile ships through)
- ADR-0010 (git identity the single-file grant preserves)

## References

- Issues #25 (spike), #30 (this pilot), #31 (sandboxed test-boot),
  #19 (bundle-ship pattern)
- https://nono.sh/docs/cli/features/profile-authoring,
  https://nono.sh/docs/cli/internals/containers,
  https://nono.sh/docs/cli/usage/troubleshooting ("Running Inside Docker/Podman")
- `nono` release `v0.76.0` (2026-09-09) `SHA256SUMS.txt`;
  registry pack `nolabs-ai/opencode 0.1.3` (profile reference)
