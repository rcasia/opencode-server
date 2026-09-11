# ADR-0021: Scale-to-zero workers per project (spike verdict)

## Status

Accepted (spike verdict for #6: reject at current scale)

## Date

2026-09-11

## Context

Issue #6 proposed replacing the single always-on EC2 host with an
always-on router plus N per-project workers that scale to zero
(stopped when idle, started on demand). The issue is a spike ending in
adopt/reject, with three acceptance items: cost vs the current burn,
a wake-latency budget, and the exact ADR list under "adopt". No
terraform/compose changes were made in this spike.

Note: #21 (cost guardrail with a documented burn rate) is still open,
so the current-burn figure below is computed from public on-demand
pricing (eu-west-1, 730 h/mo), not from the future FEATURES.md number.
Order of magnitude is what the verdict needs.

## Evidence gathered

- **Current burn (estimate, ~$19/mo).** t3.small on-demand eu-west-1
  $0.0208/h ~= $15.19/mo (cross-check: `environments/prod.tfvars`
  notes micro-to-small as +~$7.60/mo, i.e. micro ~= $7.59/mo).
  EBS gp3 $0.08/GB-mo: 30 GB root ~= $2.40 + 10 GB data disk ~=
  $0.80. Attached EIP is free; Route 53 HTTPS probe $0.50/mo; S3
  state + bundle is cents. Total ~= **$19/mo**.
- **Scale-to-zero cost (estimate, higher at every n).** The router is
  always on: cheapest viable box (t4g/t3.nano class) + EBS + EIP ~=
  **$5-7/mo floor that never sleeps**. Each stopped worker still
  pays persistent EBS (~$3.20 for root + data) plus an idle EIP at
  $3.65/mo once it is detached from a running instance; each awake
  worker pays the full ~= $15-19/mo again. At n=1 the design costs
  more than today whenever the worker is awake, and keeps a $9-14/mo
  idle floor (router + stopped-worker disks/EIP) that the current
  single host does not have a second copy of. Each added project
  grows the idle floor further. There is no project count at which
  this is cheaper for a single operator with one active project.
- **Wake-latency budget (breaks interactive use).** Cold path:
  `StartInstances` (stopped to running, typically 45-90 s) +
  systemd/docker/compose + Caddy + opencode boot, polled via
  `GET /global/health` until healthy. Expected **p50 ~= 2-3 min,
  p99 ~= 5-8 min** (AZ capacity, EBS burst, cert-renewal edge).
  Phone-interactive use expects seconds; a multi-minute wake on
  every idle-to-active transition is a regression, not a feature.
  Mitigations (hibernate, warm pool, keeping one worker always on)
  re-add exactly the cost the design was meant to remove.
- **ADRs changed under "adopt" (supersede, never rewrite).** 0002
  (CI graph becomes a per-host matrix), 0007/0015 (bundle + switch
  fan-out per worker), 0008 (per-project data volumes), 0004 (SSM
  password per worker), 0005 (domain per worker), 0006/0009
  (monitoring + probes per worker), 0010 (git identity per
  project), 0011/0015 (whatever #24 builds must be reusable per
  host), plus AGENTS.md rule 8 (cheap-by-design) and brand-new
  records for the router, `projects.yaml` schema, and worker
  image/build. That is most of the architecture file for negative
  savings.

## Considered Options

### A. Adopt: router + scale-to-zero workers (rejected)

- **Pros**: textbook idle savings; per-project isolation.
- **Cons**: higher bill at n=1 and growing idle floor per project;
  2-8 min wake latency breaks interactive use; contradicts rule 8
  and strands the #19/#24 bundle/blue-green investment, which any
  new host must re-implement; operational surface (router, fan-out
  deploys, per-worker secrets/domains/alarms) for one operator.

### B. Reject: keep the single always-on host (chosen)

- **Pros**: ~= $19/mo total, zero wake latency, current deploy and
  monitoring story untouched, no new moving parts.
- **Cons**: no per-project isolation; idle host burns the full
  $19/mo even when unused (~$0.026/h — the "waste" is pennies per
  idle day, far below the router floor in option A).

## Decision

We will **not** build scale-to-zero workers. The single always-on
host stands. Revisit only if a trigger fires: sustained multi-project
need with idle waste above ~= $50/mo, or a latency-tolerant workload
where stop/start is genuinely free.

## Rationale

At one active project the proposed architecture costs more, wakes
slower by two orders of magnitude, and rewrites most accepted ADRs
for negative savings. The honest cheap option at this scale is the
host already running.

## Consequences

### Positive

- No new cost floor, no wake latency, no deploy/monitoring fan-out.
- #19/#24 and rule 8 stay internally consistent.

### Negative

- Idle burn stays ~= $19/mo (accepted; below any router floor).
- Multi-project isolation remains unsolved (accepted; no demand).

## Implementation Notes

No build follow-ups. If a revisit trigger fires, open a new spike
that re-costs against the #21 FEATURES.md burn figure instead of
reopening this record.

## Related Decisions

- ADR-0008 (data volume), ADR-0007/0015 (deploy path), ADR-0002 (CI)
- ADR-0006/0009 (monitoring), AGENTS.md rule 8 (cheap by design)

## References

- Issue #6 (spike); #21 (burn rate, still open); #19 (bundle-ship
  pattern); #24 (deploy path any new host must reuse)
- `environments/prod.tfvars` (t3.small sizing note)
