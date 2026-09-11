# ADR-0029: AMI rotation is deliberate, never lookup drift

## Status

Accepted

## Context

The root stack resolves the host AMI with `data.aws_ami.al2023`
(`most_recent = true`). Amazon publishes AL2023 AMIs roughly every 1-2
weeks, and an AMI change forces instance replacement. Before this
record, every `deploy-prod` after a release planned `-/+`
`aws_instance.server` no matter what the commit touched: unplanned
downtime, killed agent sessions, and a surprise EBS detach/attach on a
schedule nobody chose (issue #43).

## Decision Drivers

- **Must**: deploys must be predictable — replacement happens only when
  a human opts in.
- **Must**: patching must still have a path — stale AMIs cannot become
  permanent.
- **Should**: no laptop AWS reads (pipeline-only prod, AGENTS.md rule 4),
  so AMI-ID pinning cannot rely on anyone querying prod.

## Considered Options

### Option 1: pin `ami_id` in prod.tfvars, bump deliberately

- **Pros**: fully deterministic; the bump commit is reviewable.
- **Cons**: needs the new AMI ID from somewhere — a workflow or script
  polling releases, i.e. new automation to own.

### Option 2: keep the lookup, ignore AMI drift, rotate via trigger

- **Pros**: no new automation; `lifecycle.ignore_changes = [ami]` kills
  the surprise; `replace_triggered_by` on `host_replace_trigger` plus
  the `[replace-host]` plan gate make rotation explicit and auditable.
- **Cons**: the lookup still resolves (plan shows the drift as
  ignored); a pinned-ID review trail is weaker than option 1.

## Decision

Option 2. The instance ignores AMI changes from the lookup; flipping
`host_replace_trigger` (with `[replace-host]` in the commit message,
enforced by the deploy-prod plan gate) performs a deliberate rotation
to whatever the lookup currently resolves. Pinning `ami_id` remains
available for anyone who wants a reviewed ID — it composes with the
trigger rather than replacing it.

## Consequences

- An AL2023 release no longer pages anyone: plans stay empty, deploys
  stay in place.
- Rotation is a conscious act with downtime callouts (sessions die,
  data disk re-attaches) instead of a side effect of an alarm-threshold
  tweak.
- If rotation cadence proves too ad-hoc, revisit option 1 with a
  release-watching workflow; supersede this record then, never rewrite
  it.
