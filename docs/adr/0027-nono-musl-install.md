# ADR-0027: nono Install via Static musl Tarball (RPM Path Removed)

## Status

Accepted (follow-up to #30; amends the install path in ADR-0025,
which is otherwise unchanged)

## Date

2026-09-11

## Context

ADR-0025 shipped the nono pilot with a distro RPM for the host
(`dnf install` from the S3 bundle) plus the musl tarball as the
container binary source. On the first host replacement carrying
that user_data, `dnf` failed with `Error unpacking rpm package
nono-cli-0.76.0-1.x86_64` — transaction failed, `nono --version`
never ran, and cloud-init marked scripts-user failed. The SHA256
had verified from disk, so the bundle object was intact; the
failure was in rpm unpacking on AL2023 itself. Worse, the RPM step
ran before the tarball extraction, so one package-manager failure
poisoned both the host binary and the container binary.

## Decision

Ship exactly one nono artifact: the static-pie musl tarball
(`nono-v0.76.0-x86_64-unknown-linux-musl.tar.gz`), SHA-pinned in
`app/nono-version.json` and `modules/compute/user_data.sh`
(test-boot cross-checks both). Boot verifies the checksum from
disk, extracts, and installs `/opt/opencode/nono-container`,
which compose bind-mounts into both backend colors; the same file
serves the host assert (`nono-container --version`). No `dnf`,
no rpm database, no per-arch host packages.

## Consequences

### Positive

- One fewer package-manager failure mode on the critical boot path;
  static binaries don't unpack, don't scriptlet, don't conflict.
- Single pin to bump (version + one SHA) instead of three.

### Negative

- Upstream ships musl for x86_64 only. A future move to Graviton
  (aarch64) hosts has no musl asset and reopens the install
  question — recorded here so it isn't rediscovered.
- The host `nono` on PATH (RPM benefit, used for debugging) is
  gone; the binary lives at `/opt/opencode/nono-container`.

## Related Decisions

- ADR-0025 (pilot record; this supersedes only its RPM install path)
- ADR-0003 (pinning guarantees unchanged: version + SHA in a
  reviewed diff, S3-vendored, never curl-at-boot)
- ADR-0024 (toolchain still lives in the user_data bootstrap)

## References

- Prod serial log 2026-09-11 ~18:33 UTC (`Error unpacking rpm
  package nono-cli-0.76.0-1.x86_64`, `cc_scripts_user` failure)
- `nono` release `v0.76.0` `SHA256SUMS.txt`
