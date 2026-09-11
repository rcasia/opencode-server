#!/bin/bash
# Thin bootstrap caller (ADR-0024). Host-replacing changes live ONLY here
# (disk layout, docker install, toolchain). The app and monitoring stages
# are static scripts shipped via the S3 bundle and executed below; their
# changes deploy over SSM with no replacement.
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

# Bound container log growth (ADR-0019): the json-file driver is unbounded
# by default and lands on the same data disk the alarms watch. 10m x3 per
# container, applied before any container starts below.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKER_EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
DOCKER_EOF
systemctl restart docker

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

mkdir -p /opt/opencode/logs /opt/opencode/host
rm -rf /opt/opencode/compose.yaml /opt/opencode/Caddyfile /opt/opencode/switch.sh /opt/opencode/opencode.json /opt/opencode/host/app.sh /opt/opencode/host/monitoring.sh
for _ in $(seq 1 60); do
  aws s3 cp "s3://${app_bundle_bucket}/app/compose.yaml" /opt/opencode/compose.yaml --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/Caddyfile" /opt/opencode/Caddyfile --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/switch.sh" /opt/opencode/switch.sh --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/opencode.json" /opt/opencode/opencode.json --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/host/app.sh" /opt/opencode/host/app.sh --region "${aws_region}" \
    && aws s3 cp "s3://${app_bundle_bucket}/app/host/monitoring.sh" /opt/opencode/host/monitoring.sh --region "${aws_region}" \
    && break
  sleep 5
done
test -f /opt/opencode/compose.yaml || { echo "app bundle never appeared"; exit 1; }
test -f /opt/opencode/switch.sh || { echo "app bundle never appeared"; exit 1; }
test -f /opt/opencode/opencode.json || { echo "opencode config never appeared"; exit 1; }
test -f /opt/opencode/host/app.sh || { echo "host stages never appeared"; exit 1; }
test -f /opt/opencode/host/monitoring.sh || { echo "host stages never appeared"; exit 1; }
chmod +x /opt/opencode/switch.sh /opt/opencode/host/app.sh /opt/opencode/host/monitoring.sh

# Non-secret stage config (SSM parameter NAMES, never values). Written
# once here; app/monitoring stages source it on every run, including
# SSM re-runs. Values are %q-escaped at boot so spaces in operator vars
# (e.g. git user.name) survive sourcing; single quotes in values are not
# supported. Terraform var changes re-render this file, so they still
# replace the host — only stage SCRIPT changes ship without replacement.
umask 077
{
printf 'DOMAIN=%q\n' '${domain_name}'
printf 'GITHUB_OAUTH_CLIENT_ID=%q\n' '${github_oauth_client_id}'
printf 'GITHUB_OAUTH_USER=%q\n' '${github_oauth_user}'
printf 'OPENCODE_PASSWORD_PARAMETER=%q\n' '${opencode_password_parameter}'
printf 'GITHUB_OAUTH_SECRET_PARAMETER=%q\n' '${github_oauth_secret_parameter}'
printf 'OAUTH_COOKIE_SECRET_PARAMETER=%q\n' '${oauth_cookie_secret_parameter}'
printf 'GITHUB_TOKEN_PARAMETER=%q\n' '${github_token_parameter}'
printf 'GIT_USER_NAME=%q\n' '${git_user_name}'
printf 'GIT_USER_EMAIL=%q\n' '${git_user_email}'
printf 'AWS_REGION=%q\n' '${aws_region}'
printf 'NAME_PREFIX=%q\n' '${name_prefix}'
} > /opt/opencode/stage.env
chmod 600 /opt/opencode/stage.env
cat > /opt/opencode/provider-map.sh <<'PROVIDER_EOF'
# Rendered by bootstrap: one fetch_provider call per configured provider.
%{ for env_name, parameter_name in provider_api_key_parameters ~}
%{ if parameter_name != "" ~}
fetch_provider "${env_name}" "${parameter_name}"
%{ endif ~}
%{ endfor ~}
PROVIDER_EOF
chmod 600 /opt/opencode/provider-map.sh

# Stable entry points (docs/credentials-rotation.md): thin wrappers so the
# documented rotation commands keep working while the logic lives in app.sh.
printf '#!/bin/bash\nexec /opt/opencode/host/app.sh secrets\n' > /usr/local/bin/opencode-secrets-refresh.sh
chmod 700 /usr/local/bin/opencode-secrets-refresh.sh
printf '#!/bin/bash\nexec /opt/opencode/host/app.sh git-setup\n' > /usr/local/bin/opencode-git-setup.sh
chmod +x /usr/local/bin/opencode-git-setup.sh

# Boot order: disk -> docker -> compose -> monitoring (stages below).
/opt/opencode/host/app.sh boot
/opt/opencode/host/monitoring.sh

echo 'echo "opencode web ready on https://'"${domain_name}"' (Caddy + compose in /opt/opencode)"' > /etc/profile.d/opencode.sh
