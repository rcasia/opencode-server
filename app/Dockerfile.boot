# Stage 1: published test environment (ghcr.io/rcasia/opencode-boot-test).
# Pre-installs everything user_data installs, so the script under test hits
# fast no-ops. Rebuilt rarely (only when this file changes); reused via the
# registry cache on every run.
FROM amazonlinux:2023 AS bootenv
RUN dnf install -y -q docker git tmux htop jq unzip tar rsyslog amazon-cloudwatch-agent shadow-utils e2fsprogs
RUN dnf install -y -q docker-compose-plugin || true
COPY app/stubs/ /opt/stubs/
RUN chmod +x /opt/stubs/* \
 && useradd -m ec2-user \
 && dd if=/dev/zero of=/disk.img bs=1M count=100 status=none
ENV PATH=/opt/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Stage 2: the actual test. Runs the exact rendered user_data with only
# cloud endpoints stubbed (aws SSM, systemctl, mount, Docker daemon), then
# asserts the contract. Catches script bugs, not EC2 races.
FROM bootenv AS test
ARG VOLSFX=vol0testvolume0
ARG DOMAIN=boot.test
COPY app/.rendered-user-data.sh /opt/test-user-data.sh
COPY app/compose.yaml app/Caddyfile /fixtures/
# NOTE: /dev does not persist across RUN layers, so the fake EBS device
# must be linked in the same layer that executes the script.
RUN mkdir -p /dev/disk/by-id \
 && ln -s /disk.img "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLSFX}" \
 && bash /opt/test-user-data.sh
RUN test -f /opt/opencode/compose.yaml \
 && test -f /opt/opencode/Caddyfile \
 && grep -q "^DOMAIN=${DOMAIN}$" /opt/opencode/app.env \
 && grep -q '^OPENCODE_SERVER_' /opt/opencode/app.env \
 && grep -q 'enable --now docker' /var/log/stub-systemctl.log \
 && grep -q 'enable --now rsyslog' /var/log/stub-systemctl.log \
 && grep -q 'compose up -d' /var/log/stub-docker.log \
  && grep -q 'git config' /var/log/stub-docker.log \
  && grep -q 'credential.helper' /var/log/stub-docker.log \
 && grep -q '/var/lib/docker' /etc/fstab \
 && jq empty /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
 && cd /opt/opencode && docker compose config --quiet
