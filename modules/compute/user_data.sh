#!/bin/bash
set -eux

# Slim bootstrap (ADR-0007): Docker + files + compose up. No app installs at
# boot — Caddy and opencode ship as pinned images (app/compose.yaml).
dnf update -y
dnf install -y docker git tmux htop jq unzip tar rsyslog amazon-cloudwatch-agent

# Persistent data disk (ADR-0008): format once, mount at /var/lib/docker so
# containers, images, sessions, and certs survive instance replacement.
# The EBS attach races with first boot, so wait for the device instead of
# dying instantly (an instant exit 1 here once bricked two deploys).
VOL_SFX=$(echo "${data_volume_id}" | tr -d '-')
DATA_DEV=""
for _dev in /dev/disk/by-id/*; do
  case "$(basename "$_dev")" in
    *"$VOL_SFX"*) DATA_DEV="$(basename "$_dev")"; break ;;
  esac
done
for _ in $(seq 1 60); do
  [ -n "$DATA_DEV" ] && break
  sleep 5
  for _dev in /dev/disk/by-id/*; do
    case "$(basename "$_dev")" in
      *"$VOL_SFX"*) DATA_DEV="$(basename "$_dev")"; break ;;
    esac
  done
done
[ -n "$DATA_DEV" ] || { echo "data volume ${data_volume_id} never attached"; exit 1; }
DEVICE="/dev/disk/by-id/$DATA_DEV"
blkid "$DEVICE" >/dev/null 2>&1 || mkfs -t ext4 "$DEVICE"
UUID=$(blkid -s UUID -o value "$DEVICE")
mkdir -p /var/lib/docker
grep -q "$UUID" /etc/fstab 2>/dev/null || echo "UUID=$UUID /var/lib/docker ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

systemctl enable --now docker
usermod -aG docker ec2-user || true

# AWS CLI v2 (SSM password fetch below)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update 2>/dev/null || /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Docker Compose plugin (dnf, fallback to GitHub release for the host arch)
dnf install -y docker-compose-plugin || {
  # shellcheck disable=SC2034
  # (double-dollar escapes render shell expansions; shellcheck sees $$ = PID)
  TAG=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
  # shellcheck disable=SC2034
  # (same double-dollar escape as TAG above)
  ARCH=$(uname -m)
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/$${TAG}/docker-compose-linux-$${ARCH}" -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}
docker compose version

# App stack (single source of truth: app/ in the repo, via templatefile).
# rm -rf first: a previous boot once left Caddyfile behind as a directory
# (Docker bind-mount auto-creation), which made `cat` fail and killed boot.
mkdir -p /opt/opencode/logs
ls -la /opt/opencode/
rm -rf /opt/opencode/compose.yaml /opt/opencode/Caddyfile
cat > /opt/opencode/compose.yaml <<'COMPOSE_EOF'
${compose_yaml}
COMPOSE_EOF
cat > /opt/opencode/Caddyfile <<'CADDY_EOF'
${caddyfile}
CADDY_EOF
cat > /opt/opencode/app.env <<ENV_EOF
DOMAIN=${domain_name}
ENV_EOF

# OPENCODE_SERVER_PASSWORD from SSM (ADR-0004): never in repo/state.
VALUE=$(aws ssm get-parameter --name "${opencode_password_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$VALUE" >> /opt/opencode/app.env
chmod 600 /opt/opencode/app.env

cd /opt/opencode
docker compose up -d
docker compose ps

# Intrusion visibility (ADR-0006): ship Caddy access logs + sshd syslog to
# CloudWatch (alarms in modules/monitoring).
systemctl enable --now rsyslog
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CW_EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/opencode/logs/access.log",
            "log_group_name": "${name_prefix}-caddy",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/secure",
            "log_group_name": "${name_prefix}-secure",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "${name_prefix}-boot",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/lib/docker/containers/*/*.log",
            "log_group_name": "${name_prefix}-containers",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CW_EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  || echo "WARNING: cloudwatch agent config failed; continuing without log shipping" >&2

echo 'echo "opencode web ready on https://'"${domain_name}"' (Caddy + compose in /opt/opencode)"' > /etc/profile.d/opencode.sh
