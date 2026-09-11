# ADR-0030: Data-disk backup via DLM snapshots

## Status

Accepted

## Context

All persistent state — sessions, workspace, `.git-credentials`, Caddy
certs — lives on one 10 GB gp3 volume in one AZ (ADR-0008). ADR-0008
rejected an S3 backup cron but never considered EBS snapshots, so until
this record there was no backup at all: volume corruption, an
accidental destroy, or an AZ event meant total loss (issue #46). This
record amends ADR-0008's scope; ADR-0008 itself is untouched.

## Decision Drivers

- **Must**: backups with no daemons and no host IAM (the host already
  runs enough).
- **Must**: restores must be a documented runbook, not improvisation.
- **Should**: cents per month (10 GB, 7 daily snapshots max).

## Considered Options

### Option 1: EBS snapshots via Data Lifecycle Manager

- **Pros**: zero daemons, no host credentials, tag-targeted, lifecycle
  retention built in; snapshots inherit source encryption.
- **Cons**: restores still need a few manual steps (documented in
  `docs/restore-data-volume.md`).

### Option 2: S3 sync cron on the host

- **Pros**: file-level restores.
- **Cons**: rejected shape from ADR-0008 (host IAM, daemon, partial
  copies of live SQLite); re-litigating it here adds nothing.

## Decision

Option 1: a DLM policy (`Name = <prefix>-data`, daily 03:00, keep 7,
copy tags) managed in `modules/compute` with its service-linked role.
The volume attachment stops the instance before detaching so
replacements unmount cleanly instead of tearing a mounted ext4.

## Consequences

- Worst case is now "lose up to 24h of sessions", not "lose everything".
- Restores stay manual by design (rare, high-stakes, human-gated) —
  see `docs/restore-data-volume.md`.
- Snapshot storage shows up on the bill as a few cents; a cost alarm
  change is not warranted.
