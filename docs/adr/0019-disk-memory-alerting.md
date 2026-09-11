# ADR-0019: Disk and Memory Alerting with Bounded Log Growth

## Status

Accepted

## Date

2026-09-11

## Context

The data disk (`/var/lib/docker`, ADR-0008) fills silently — images,
sessions, Caddy logs, container json logs. Intrusion and uptime alarms
(ADR-0006, ADR-0009) say nothing about a full disk, and a full disk
means dead sessions with no warning. Memory has the same shape on a
2 GB host: the agent backend OOMs with no warning.

Three unbounded growers were found:

- Container json logs: the `json-file` driver keeps every line forever
  under `/var/lib/docker` unless capped.
- Stale images: each blue-green deploy leaves the previous backend
  image behind.
- Caddy access log: already capped at 10 MB x3 in `app/Caddyfile`
  (roll_size/roll_keep) — confirmed enough, no change needed.

## Decision Drivers

- **Must page before the disk fills**: warn at 80%, not at 100%.
- **Must not delete state**: workspace, opencode data, and Caddy state
  live in named volumes on the same disk — pruning must be images only.
- **Should cost cents**: CloudWatch agent metrics + two alarms, same
  SNS topic as ADR-0006.

## Considered Options

### Option 1: Agent metrics + alarms + daemon caps + weekly image prune (chosen)

`amazon-cloudwatch-agent` collects `mem_used_percent` and
`disk_used_percent` (`/`, `/var/lib/docker`); alarms page at
disk > 80% and mem > 90% sustained 15 min. `/etc/docker/daemon.json`
caps every container log at 10 MB x3 before any container starts; a
weekly systemd timer runs `docker image prune -af` (never `--volumes`).

- **Pros**: bounded growth by construction; alarm fires only when the
  bounds fail; pennies per month.
- **Cons**: weekly cadence means a pathological image spree can still
  fill the disk mid-week (the 80% alarm covers that window).

### Option 2: Aggressive auto-prune with volumes (rejected)

`docker system prune -af --volumes` on a timer would also wipe the
workspace and session volumes — destroys the state ADR-0008 exists to
keep. Never prune volumes automatically.

### Option 3: Larger data disk instead of alarms (rejected)

A bigger disk delays the same silent failure and costs more every
month (repo rule 8). Alarms are cheaper than gigabytes.

## Decision

We will collect host `mem`/`disk` metrics via the CloudWatch agent,
alarm at disk > 80% and mem > 90% (15 min) to the existing SNS topic,
cap container logs at the daemon, prune unused images weekly, and rely
on the existing Caddy 10 MB x3 rotation.

## Rationale

Growth is bounded at three layers (daemon caps, Caddy rotation,
weekly prune); the alarm is the backstop for abnormal use, not the
primary control.

## Consequences

### Positive

- Disk pressure pages before sessions die; memory pressure pages
  before the backend OOMs.
- `docker image prune -af` is state-safe: named volumes are untouched.

### Negative

- New alarms add cents per month (called out per repo rule 8).
- Moto does not implement `PutMetricAlarm`: the `local` job stays
  plan-only for monitoring, same pattern as the existing alarms.

## Implementation Notes

- `modules/monitoring`: `disk_high`, `mem_high` alarms (CWAgent
  namespace, `InstanceId` + `path` dimensions); threshold vars
  `disk_threshold_percent` (80) / `mem_threshold_percent` (90).
- `modules/compute/user_data.sh` (additive only): `metrics` section
  in the agent config, `/etc/docker/daemon.json` log caps,
  `docker-prune.{service,timer}` weekly.

## Related Decisions

- ADR-0006 (same SNS topic and email path)
- ADR-0008 (the data disk being watched)

## References

- Issue #20
