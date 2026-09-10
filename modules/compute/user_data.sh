#!/bin/bash
set -eux

# Agentic coding server bootstrap: Docker + Node 22 + opencode
dnf update -y
dnf install -y docker git tmux htop jq unzip tar

systemctl enable --now docker
usermod -aG docker ec2-user || true

# Node 22 LTS
curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
dnf install -y nodejs
node --version
npm --version

# opencode (https://opencode.ai)
curl -fsSL https://opencode.ai/install | bash
mv /root/.opencode/bin/opencode /usr/local/bin/opencode 2>/dev/null || true
ln -sf /usr/local/bin/opencode /usr/bin/opencode 2>/dev/null || true
chmod +x /usr/local/bin/opencode 2>/dev/null || true

# AWS CLI v2 (for fetching the opencode password from SSM)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update 2>/dev/null || /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Fetch OPENCODE_SERVER_PASSWORD from SSM into a root-only env file.
# See ADR-0001: password never touches the repo, tfvars, or state.
cat > /usr/local/bin/opencode-web-env.sh <<ENV_EOF
#!/bin/bash
set -euo pipefail
VALUE=\$(aws ssm get-parameter --name "${opencode_password_parameter}" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
printf 'OPENCODE_SERVER_PASSWORD=%s\n' "\$VALUE" > /run/opencode-web.env
chmod 600 /run/opencode-web.env
ENV_EOF
chmod 700 /usr/local/bin/opencode-web-env.sh

# opencode web as a systemd service, bound to localhost only.
# Public traffic arrives via Caddy (TLS) on 80/443; see ADR-0001.
cat > /etc/systemd/system/opencode-web.service <<UNIT_EOF
[Unit]
Description=opencode web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user
ExecStartPre=/usr/local/bin/opencode-web-env.sh
EnvironmentFile=/run/opencode-web.env
Environment=BROWSER=true
ExecStart=/usr/local/bin/opencode web --hostname 127.0.0.1 --port ${opencode_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable --now opencode-web.service

# Caddy reverse proxy with automatic Let's Encrypt TLS (ADR-0001).
dnf install -y 'dnf-command(copr)'
dnf copr enable -y @caddy/caddy
dnf install -y caddy
if [ -n "${domain_name}" ]; then
  cat > /etc/caddy/Caddyfile <<CADDY_EOF
${domain_name} {
	reverse_proxy 127.0.0.1:${opencode_port}
}
CADDY_EOF
  systemctl enable --now caddy
fi

# Persist port info for motd
echo "OPENCODE_PORT=${opencode_port}" > /etc/opencode-server
echo 'echo "opencode web ready on https://'"${domain_name}"' (via Caddy) and http://127.0.0.1:$(cat /etc/opencode-server | cut -d= -f2) locally"' >> /etc/profile.d/opencode.sh
