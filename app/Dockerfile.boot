# Bootstrap test (ADR-0007): executes the EXACT rendered user_data.sh
# (extracted from applied mock state by scripts/test-bootstrap.sh) in
# Amazon Linux 2023 with only cloud endpoints stubbed:
#   aws            -> answers the SSM get-parameter call with a dummy
#   systemctl      -> logged, always succeeds (no systemd in build)
#   amazon-cloudwatch-agent-ctl -> logged, succeeds (fetch needs IMDS)
#   docker         -> daemon calls faked; version/config run for real
#   mount          -> logged, succeeds (no privileges in build)
# A fake EBS device (ext4 file + by-id symlink) exercises the real
# format-once/mount/fstab logic. Catches script bugs, not EC2 races.
FROM amazonlinux:2023
ARG VOLSFX=vol0testvolume0
ARG DOMAIN=boot.test
RUN dnf install -y -q shadow-utils e2fsprogs
COPY app/stubs/ /opt/stubs/
COPY app/.rendered-user-data.sh /opt/test-user-data.sh
COPY app/compose.yaml app/Caddyfile /fixtures/
ENV PATH=/opt/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN chmod +x /opt/stubs/* \
 && useradd -m ec2-user \
 && dd if=/dev/zero of=/disk.img bs=1M count=100 status=none \
 && mkdir -p /dev/disk/by-id \
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
 && grep -q '/var/lib/docker' /etc/fstab \
 && jq empty /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
 && cd /opt/opencode && docker compose config --quiet
