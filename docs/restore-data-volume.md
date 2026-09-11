# Restore the data volume from a snapshot

The persistent volume (`opencode-prod-data`, 10 GB gp3, `eu-west-1a`)
holds sessions, workspace, `.git-credentials`, and Caddy state. DLM
takes a daily snapshot at 03:00 and keeps 7 (ADR-0030). Use this
procedure when the volume is corrupt, was destroyed, or must move —
never improvise a restore.

Conventions: region `eu-west-1`. The `aws` commands run from any admin
machine with AWS access. Replacing the attachment restarts the host;
in-flight agent sessions die — announce the window first.

## 1. Pick the snapshot

```bash
aws ec2 describe-snapshots --region eu-west-1 --owner-ids self \
  --filters 'Name=tag:Name,Values=opencode-prod-data' \
  --query 'sort_by(Snapshots, &StartTime)[-3:].[SnapshotId,StartTime,VolumeSize]' \
  --output table
```

Take the newest snapshot started **before** the corruption/loss (not
necessarily the newest overall).

## 2. Create a replacement volume in the same AZ

```bash
aws ec2 create-volume --region eu-west-1 \
  --availability-zone eu-west-1a --volume-type gp3 \
  --snapshot-id snap-CHOSEN \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=opencode-prod-data-new}]' \
  --query 'Volume.VolumeId' --output text
aws ec2 wait volume-available --region eu-west-1 --volume-ids vol-NEW
```

## 3. Stop the instance, swap the attachment, start

```bash
IID=$(aws ec2 describe-instances --region eu-west-1 \
  --filters 'Name=tag:Name,Values=opencode-prod-server' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 stop-instances --region eu-west-1 --instance-ids "$IID"
aws ec2 wait instance-stopped --region eu-west-1 --instance-ids "$IID"
# Detach the damaged volume (Terraform still manages the attachment
# resource — this manual detach is only the emergency path; afterwards
# either re-attach the same volume id or import the new one).
aws ec2 detach-volume --region eu-west-1 --volume-id vol-DAMAGED
aws ec2 wait volume-available --region eu-west-1 --volume-ids vol-DAMAGED
aws ec2 attach-volume --region eu-west-1 --volume-id vol-NEW \
  --instance-id "$IID" --device /dev/sdf
aws ec2 wait volume-in-use --region eu-west-1 --volume-ids vol-NEW
aws ec2 start-instances --region eu-west-1 --instance-ids "$IID"
```

## 4. Reconcile Terraform state

The attachment resource still points at the old volume id, so the next
plan will show a diff. Either:

- (preferred) `terraform import` the new volume into
  `module.compute.aws_ebs_volume.data` after removing the old one from
  state — pipeline-only, never from a laptop; or
- push a no-op and let the plan surface the drift for review.

Then verify: `https://<domain>/ready` answers `ready`, SSO login works,
and `docker compose ps` on the host shows one live color.

## 5. Clean up

Delete the damaged volume only after the restored host has served
traffic for a full day. Keep at least one pre-incident snapshot until
the next DLM cycle ages it out.
