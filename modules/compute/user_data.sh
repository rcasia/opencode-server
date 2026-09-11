#!/bin/bash
set -eux

dnf update -y
dnf install -y docker git tmux htop jq unzip tar rsyslog amazon-cloudwatch-agent

VOL_SFX=$(echo "${data_volume_id}" | tr -d '-')
DATA_DEV=""
for _dev in /dev/disk/by-id/*; do
  case "$(basename "$_dev")" in *"$VOL_SFX"*) DATA_DEV="$(basename "$_dev")"; break;; esac
done
for _ in $(seq 1 60); do
  [ -n "$DATA_DEV" ] && break
  sleep 5
  for _dev in /dev/disk/by-id/*; do
    case "$(basename "$_dev")" in *"$VOL_SFX"*) DATA_DEV="$(basename "$_dev")"; break;; esac
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

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update 2>/dev/null || /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

dnf install -y docker-compose-plugin || {
  COMPOSE_VERSION="v5.5.1"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) EXPECTED_SHA256="db1889184726840f75c4f9c001048430d4f25b3be3cb084d3ddd762bc0aed576" ;; # pragma: allowlist secret -- pinned release hash, not a credential
    aarch64) EXPECTED_SHA256="732e3a84c1a0f67256ce80bc2598a24546b10ca05f9faa97efceb1171ece2ef7" ;; # pragma: allowlist secret -- pinned release hash, not a credential
    *) echo "unsupported arch $ARCH for compose fallback"; exit 1 ;;
  esac
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$ARCH" -o /usr/local/lib/docker/cli-plugins/docker-compose
  ACTUAL_SHA256=$(sha256sum /usr/local/lib/docker/cli-plugins/docker-compose | cut -d ' ' -f 1)
  [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || { echo "compose checksum mismatch"; exit 1; }
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}
docker compose version

mkdir -p /opt/opencode/logs
rm -rf /opt/opencode/compose.yaml /opt/opencode/Caddyfile /opt/opencode/switch.sh /opt/opencode/opencode.json
for _ in $(seq 1 60); do
  aws s3 cp "s3://${app_bundle_bucket}/app/compose.yaml" /opt/opencode/compose.yaml --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/Caddyfile" /opt/opencode/Caddyfile --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/switch.sh" /opt/opencode/switch.sh --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/opencode.json" /opt/opencode/opencode.json --region "${aws_region}" \
    && break
  sleep 5
done
test -f /opt/opencode/compose.yaml || { echo "app bundle never appeared"; exit 1; }
test -f /opt/opencode/switch.sh || { echo "app bundle never appeared"; exit 1; }
test -f /opt/opencode/opencode.json || { echo "opencode config never appeared"; exit 1; }
chmod +x /opt/opencode/switch.sh

# Re-fetches all runtime secrets from SSM without tracing. This is also the
# single manual rotation path: update SSM, run this script, then switch the
# backend color so the new environment is picked up without host replacement.
cat > /usr/local/bin/opencode-secrets-refresh.sh <<'SECRET_EOF'
#!/bin/bash
set +x
set -euo pipefail
umask 077
TMP=$(mktemp /opt/opencode/app.env.XXXXXX)
trap 'rm -f "$TMP"' EXIT
printf 'DOMAIN=%s\n' "${domain_name}" >> "$TMP"
printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' "${github_oauth_client_id}" >> "$TMP"
printf 'OAUTH2_PROXY_GITHUB_USERS=%s\n' "${github_oauth_user}" >> "$TMP"
printf 'OAUTH2_PROXY_REDIRECT_URL=https://%s/oauth2/callback\n' "${domain_name}" >> "$TMP"
VALUE=$(aws ssm get-parameter --name "${opencode_password_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$VALUE" >> "$TMP"
BASIC=$(printf 'opencode:%s' "$VALUE" | base64 | tr -d '\n')
printf 'BASIC_AUTH=%s\n' "$BASIC" >> "$TMP" # pragma: allowlist secret -- derived from an SSM secret at runtime
unset VALUE BASIC
OAUTH_SECRET=$(aws ssm get-parameter --name "${github_oauth_secret_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$OAUTH_SECRET" >> "$TMP"
unset OAUTH_SECRET
COOKIE_SECRET=$(aws ssm get-parameter --name "${oauth_cookie_secret_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "$COOKIE_SECRET" >> "$TMP"
unset COOKIE_SECRET
%{ for env_name, parameter_name in provider_api_key_parameters ~}
%{ if parameter_name != "" ~}
PROVIDER_VALUE=$(aws ssm get-parameter --name "${parameter_name}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf '${env_name}=%s\n' "$PROVIDER_VALUE" >> "$TMP"
unset PROVIDER_VALUE
%{ endif ~}
%{ endfor ~}
chmod 600 "$TMP"
mv -f "$TMP" /opt/opencode/app.env
trap - EXIT
SECRET_EOF
chmod 700 /usr/local/bin/opencode-secrets-refresh.sh
/usr/local/bin/opencode-secrets-refresh.sh

cd /opt/opencode
docker compose up -d caddy oauth2-proxy opencode-blue
echo blue > /opt/opencode/.live-color
docker compose ps

cat > /usr/local/bin/opencode-git-setup.sh <<'GIT_EOF'
#!/bin/bash
set +x
set -euo pipefail
COMPOSE="docker compose -f /opt/opencode/compose.yaml"
LIVE=$(cat /opt/opencode/.live-color 2>/dev/null || echo blue)
TARGET="opencode-$LIVE"
for _ in $(seq 1 120); do
  $COMPOSE ps --status running --services 2>/dev/null | grep -q "^$TARGET$" && break
  sleep 5
done
GH_PAT=$(aws ssm get-parameter --name "${github_token_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
[ -n "${git_user_name}" ] && $COMPOSE exec -T $TARGET git config --global user.name "${git_user_name}" || true
[ -n "${git_user_email}" ] && $COMPOSE exec -T $TARGET git config --global user.email "${git_user_email}" || true
$COMPOSE exec -T $TARGET git config --global credential.helper store
printf 'https://x-access-token:%s@github.com\n' "$GH_PAT" | $COMPOSE exec -T -i $TARGET sh -c 'cat > /root/.git-credentials && chmod 600 /root/.git-credentials' # pragma: allowlist secret
$COMPOSE exec -T $TARGET git config --global credential.helper | grep -q '^store$' || { echo "WARNING: git credential helper not applied" >&2; exit 1; }
GIT_EOF
chmod +x /usr/local/bin/opencode-git-setup.sh
/usr/local/bin/opencode-git-setup.sh || echo "WARNING: git setup failed; re-run /usr/local/bin/opencode-git-setup.sh" >&2

cat > /etc/systemd/system/opencode-colors.service <<'UNIT_EOF'
[Unit]
Description=Reconcile opencode blue-green colors after boot
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/opencode/switch.sh reconcile

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable opencode-colors.service

systemctl enable --now rsyslog
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CW_EOF
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "logs": { "logs_collected": { "files": { "collect_list": [
    { "file_path": "/opt/opencode/logs/access.log", "log_group_name": "${name_prefix}-caddy", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/log/secure", "log_group_name": "${name_prefix}-secure", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/log/cloud-init-output.log", "log_group_name": "${name_prefix}-boot", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/lib/docker/containers/*/*.log", "log_group_name": "${name_prefix}-containers", "log_stream_name": "{instance_id}" }
  ] } } }
CW_EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  || echo "WARNING: cloudwatch agent config failed; continuing without log shipping" >&2

echo 'echo "opencode web ready on https://'"${domain_name}"' (Caddy + compose in /opt/opencode)"' > /etc/profile.d/opencode.sh
