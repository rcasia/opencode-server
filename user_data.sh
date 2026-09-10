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

# Persist port info for motd
echo "OPENCODE_PORT=${opencode_port}" > /etc/opencode-server
echo 'echo "opencode server ready. Run: opencode serve --port $(cat /etc/opencode-server | cut -d= -f2) --hostname 0.0.0.0"' >> /etc/profile.d/opencode.sh
