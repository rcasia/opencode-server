# ADR-0008: Persistent Data Volume for Deploy-Often

## Status

Accepted

## Date

2026-09-10

## Context

Frequent deploys are the goal (ADR-0002), and any `user_data` change
replaces the instance (forced since the v6-default incident). Container
state lived on the root EBS, which dies with the instance — so every
bootstrap-changing deploy wiped opencode sessions, config, and Caddy
certs. That made deploying often a data-loss risk: a blocker.

## Decision Drivers

- **Must survive replacement** — sessions, config, workspace, certs, and
  ideally pulled images persist across instance swaps.
- **Should stay cheap and simple** — one box, no EFS, no backup daemons.
- **Should also speed up boots** — reused images beat re-pulled ones.

## Considered Options

### Option 1: Separate EBS data volume at `/var/lib/docker` (chosen)

A 10 GB encrypted gp3 volume in the instance AZ, attached as `/dev/sdf`,
formatted-once + fstab-mounted at `/var/lib/docker` before Docker starts.
All compose named volumes (sessions, config, workspace, Caddy data) then
live on persistent disk automatically; so do pulled images.

- **Pros**: everything survives except a full `terraform destroy`; boots
  get faster (warm image cache); ~$0.80/mo.
- **Cons**: tied to one AZ (already true — single-AZ design); first volume
  starts empty (current sessions don't migrate); `terraform destroy`
  still deletes it.

### Option 2: EFS (rejected)

Multi-AZ file system for a single-AZ box — cost and complexity with no
benefit here.

### Option 3: S3 backup cron (rejected for now)

Covers even `destroy`, but a daemon, IAM writes, and restore runbooks for
a risk (`destroy`) already gated by "explicit confirmation only". Revisit
if sessions become irreplaceable.

## Decision

We will attach a **persistent 10 GB encrypted EBS data volume mounted at
`/var/lib/docker`**, with deliberately **no `prevent_destroy`** (it would
break `destroy-local` teardown; destruction stays protected by process,
not by Terraform).

## Rationale

One cheap volume removes the only data-loss vector in the normal deploy
loop, and the warm image cache makes frequent deploys faster too.

## Consequences

### Positive

- Deploy as often as wanted: replacement keeps sessions, certs, images.
- Reboots are trivially safe (fstab `nofail` mount + `unless-stopped`).

### Negative

- ~$0.80/mo recurring (called out per repo rule 8).
- Volume is AZ-bound like the instance (no change in practice).
- `terraform destroy` deletes it — process-gated, same as everything else.

## Implementation Notes

- `modules/compute`: `aws_ebs_volume` + `aws_volume_attachment`;
  `user_data.sh` resolves the device via `/dev/disk/by-id` from the
  volume ID (nitro naming), formats only if blank, fstab-persists.
- Caddy logs already bind-mounted under `/opt/opencode/logs` (root disk,
  ephemeral) — only shipped logs (CloudWatch) survive; accepted, logs are
  not sessions.

## Related Decisions

- ADR-0002 (deploy often — this unblocks it)
- ADR-0006 (alerting unaffected: log shipping path unchanged)
- ADR-0007 (compose named volumes are what persist)

## References

- [EBS volumes](https://docs.aws.amazon.com/ec2/latest/userguide/ebs-volumes.html)
