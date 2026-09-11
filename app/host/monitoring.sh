#!/bin/bash
# Monitoring stage of instance boot (ADR-0024). Installs the CloudWatch
# agent config, the weekly image-prune timer, and rsyslog. Idempotent:
# safe to run at boot and to re-run over SSM on monitoring-only changes
# with no host replacement.
#
# Static file: shipped via the S3 app bundle, never rendered by
# Terraform. Non-secret config comes from /opt/opencode/stage.env.
set -euo pipefail

OPT_DIR="${OPT_DIR:-/opt/opencode}"
STAGE_ENV="${STAGE_ENV:-$OPT_DIR/stage.env}"

[ -f "$STAGE_ENV" ] || { echo "FATAL: $STAGE_ENV missing (bootstrap must run first)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STAGE_ENV"
: "${AWS_REGION:?stage.env must set AWS_REGION}"
: "${NAME_PREFIX:?stage.env must set NAME_PREFIX}"

systemctl enable --now rsyslog

# Weekly image prune (ADR-0019): stale backend/edge images are the main
# disk hog. Images only, never volumes: workspace, opencode data, and
# Caddy state live in named volumes on this disk and must survive.
cat > /etc/systemd/system/docker-prune.service <<'PRUNE_EOF'
[Unit]
Description=Prune unused Docker images
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af
PRUNE_EOF
cat > /etc/systemd/system/docker-prune.timer <<'PRUNE_TIMER_EOF'
[Unit]
Description=Weekly Docker image prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
PRUNE_TIMER_EOF
systemctl daemon-reload
systemctl enable --now docker-prune.timer

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CW_EOF
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "metrics": { "metrics_collected": {
    "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 },
    "disk": { "measurement": ["used_percent"], "metrics_collection_interval": 60, "resources": ["/", "/var/lib/docker"] }
  } },
  "logs": { "logs_collected": { "files": { "collect_list": [
    { "file_path": "/opt/opencode/logs/access.log", "log_group_name": "${NAME_PREFIX}-caddy", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/log/secure", "log_group_name": "${NAME_PREFIX}-secure", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/log/cloud-init-output.log", "log_group_name": "${NAME_PREFIX}-boot", "log_stream_name": "{instance_id}" }
    // NOTE (issue #55): container stdout is DELIBERATELY not shipped.
    // The agent prints prompts, file contents, and API responses, so
    // off-host retention would keep echoed secrets readable account-wide.
    // Backend logs stay local only (`docker logs`, bounded 10m x3 by the
    // daemon config in user_data.sh).
  ] } } }
CW_EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  || echo "WARNING: cloudwatch agent config failed; continuing without log shipping" >&2
# A dead agent is otherwise silent (metrics/alarms/log shipping all
# dark while systemd restart-loops it). Report it loudly at boot so
# the boot-warnings audit surfaces it; never fail boot over it.
sleep 10
if systemctl is-active --quiet amazon-cloudwatch-agent; then
  echo "cloudwatch agent active"
else
  echo "WARNING: cloudwatch agent not active after fetch-config" >&2
  systemctl status amazon-cloudwatch-agent --no-pager 2>&1 | tail -n 15 >&2 || true
  tail -n 30 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log 2>&1 >&2 || true
fi
true
