# ADR-0020: Sandbox opencode with nono (spike verdict)

## Status

Accepted (spike verdict for #25; pilot not yet implemented)

## Date

2026-09-11

## Context

The `opencode` container (`app/compose.yaml`, `opencode-blue`/`opencode-green`
services) runs unsandboxed: it mounts `/var/run/docker.sock`
(host-root-equivalent), the full workspace, and sits next to `app.env` with
all secrets. `app/opencode.json` sets `permission: {"*": "allow"}`, which is
LLM-enforced only — a tricked agent can read credentials (IMDS,
`~/.aws`), other sessions, and own the host.

Issue #25 asked for a no-commitment spike on `nono`
(Landlock/kernel-enforced sandbox, https://nono.sh) wrapping the container
command (`nono run --profile X -- opencode web ...`), with three acceptance
items: `test-boot` proof, a `docker.sock` verdict, and an adopt/reject
verdict.

## Evidence gathered (no terraform/compose changes in this spike)

- **nono exists and fits the threat model.** nono enforces irrevocable
  kernel allow-lists (Landlock LSM on Linux kernel 5.13+; AL2023 ships
  6.x, so the prod host qualifies), ships a signed `opencode` profile in
  its registry, and supports exactly the policy shape #25 proposed:
  allow workspace + port + provider/GitHub egress, deny secrets paths,
  `~/.aws`/`~/.ssh`, and IMDS, with audit + rollback.
- **Install path satisfies ADR-0003 without curl-at-boot.** nono publishes
  pinned `.deb`/`.rpm` assets per GitHub Release (plus Homebrew/Nix/AUR).
  AL2023 is RPM-based, so the compliant path is a pinned
  `nono-cli-<version>.<arch>.rpm` with a verified SHA256, vendored through
  the existing S3 bundle pattern (#19) and installed from disk — the same
  treatment as compose images (`tag@digest`). `curl
  https://nono.sh/install.sh | sh` (latest-tracking) is rejected for the
  host for the same reason ADR-0003 rejects mutable action tags. Release
  bumps arrive as reviewed diffs with a release-date check.
- **test-boot evidence: not runnable in this lane, and currently asserts
  the unsandboxed stack.** This environment has no Docker daemon, so
  `make test-boot` could not be executed here. More importantly, the
  current `scripts/test-boot.sh` brings up the exact prod compose stack
  *with* `docker.sock` mounted and asserts only SSO/TLS/switch behavior —
  it proves nothing about sandboxing today. The sandboxed proof (web +
  SSO gate + git + model call with dummy creds under the nono profile)
  is therefore recorded as follow-up work, not as spike evidence.

## Considered Options

### A. Adopt: nono pilot with `docker.sock` CUT (chosen)

Wrap the backend command with the checked-in profile shipped via the S3
bundle. Agent `docker build`/`run` stops working inside the sandbox.

- **Pros**: removes the single worst primitive (host-root via daemon);
  kernel-enforced, not prompt-enforced; profile is versioned JSON next to
  `opencode.json`; audit trail answers "what did the agent touch".
- **Cons**: functional regression for agent-driven docker builds (must move
  to a host-side workflow or an explicit, human-approved escape hatch);
  one more pinned binary to bump via Dependabot-style review.

### B. Adopt with `docker.sock` ALLOWED

Sandbox everything except the daemon socket.

- **Rejected**: keeping a host-root-equivalent fd inside the sandbox voids
  the sandbox. Policy theater, not least privilege.

### C. Reject nono entirely

- **Rejected**: the threat (`permission: allow` + docker.sock + secrets on
  disk) is real and kernel enforcement is the only fix class that survives
  a tricked agent. No cheaper primitive (seccomp profiles, read-only
  mounts alone) covers file+network+credential scoping with audit.

## Decision

We will pilot nono around `opencode web` with **`docker.sock` CUT**.
Consequence, stated plainly: **the agent loses the ability to run docker
builds**; container work moves outside the sandbox until/unless a brokered
docker path is proposed and accepted separately. The profile lives in
`app/`, ships via the S3 bundle (#19 pattern), and the binary installs
from a pinned, checksummed RPM — never `curl | sh` at boot.

## Rationale

The sandbox removes host-root while preserving everything interactive use
needs (workspace, port 4096, provider + GitHub egress, one injected
credential). Cutting the socket is the whole point: an allowed
`docker.sock` is a sandbox with a host-root backdoor. The install path
keeps ADR-0003 intact, so supply-chain hygiene does not regress.

## Consequences

### Positive

- Kernel-enforced least privilege replaces LLM-enforced `permission:
  allow` as the real boundary.
- Tamper-evident audit of agent file/network actions.

### Negative

- Agent docker builds break (accepted; documented above).
- Pinned-binary bump stream (mitigation: same grouped, cooldown-gated
  review as other supply-chain items).
- `test-boot` must grow sandbox assertions before the pilot ships
  (follow-up, not this spike).

## Implementation Notes (follow-ups, not this commit)

1. New issue: vendor pinned nono RPM + `app/nono-profile.json` via the S3
   bundle; wrap backend command.
2. New issue: extend `test-boot` with sandboxed assertions (SSO gate, git,
   model call with dummy creds, negative probes for IMDS/`~/.aws`/
   `docker.sock`).
3. On pilot landing: update `docs/FEATURES.md` (rule 10) and supersede
   this record if the design changes. Profile versioning policy rides
   with follow-up 1.

## Related Decisions

- ADR-0003 (supply-chain hygiene the install path must satisfy)
- ADR-0004 (secret handling for the app password; the secrets nono denies)
- ADR-0007 (compose deployment the profile ships with)

## References

- Issue #25 (spike); #19 (bundle-ship pattern); #23 (credential injection)
- https://nono.sh, https://nono.sh/docs/cli/getting_started/installation,
  opencode profile in the nono registry
- `app/compose.yaml` (`docker.sock` mounts), `app/opencode.json`
  (`permission: allow`), `scripts/test-boot.sh`
