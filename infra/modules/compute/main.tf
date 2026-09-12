# IAM role for SSM (keyless access), optional SSH key, EC2 + EIP.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Deliberate-rotation trigger (issue #43, ADR-0029): changing
# host_replace_trigger taints this, which replaces the instance via
# replace_triggered_by. Value never matters, only changes.
resource "terraform_data" "host_replace" {
  input = var.host_replace_trigger
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "opencode_password" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.opencode_password_parameter}"]
  }
}

resource "aws_iam_role_policy" "opencode_password" {
  name   = "${var.name_prefix}-opencode-password"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.opencode_password.json
}

# SSO secrets (ADR-0014): the instance alone can read the GitHub OAuth
# client secret and the oauth2-proxy cookie secret via SSM Parameter
# Store. Nothing else (deploy role, CI, state) holds GetParameter for
# them — same shape as ADR-0004. This is NOT a no-execute boundary:
# the deploy role's scoped SendCommand runs root commands on this host
# (issue #41), so command output can still exfiltrate whatever the host
# holds; the guarantee is Parameter Store scoping only.
data "aws_iam_policy_document" "oauth_secrets" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.github_oauth_secret_parameter}",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.oauth_cookie_secret_parameter}",
    ]
  }
}

resource "aws_iam_role_policy" "oauth_secrets" {
  name   = "${var.name_prefix}-oauth-secrets"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.oauth_secrets.json
}

# Provider credentials follow the same discipline: Terraform carries only
# parameter names, never secret values. Empty names disable that provider.
data "aws_iam_policy_document" "provider_api_keys" {
  count = length([for p in values(var.provider_api_key_parameters) : p if p != ""]) > 0 ? 1 : 0

  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      for parameter_name in values(var.provider_api_key_parameters) :
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${parameter_name}"
      if parameter_name != ""
    ]
  }
}

resource "aws_iam_role_policy" "provider_api_keys" {
  count  = length([for p in values(var.provider_api_key_parameters) : p if p != ""]) > 0 ? 1 : 0
  name   = "${var.name_prefix}-provider-api-keys"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.provider_api_keys[0].json
}

# The boot git helper (and deploy-app re-apply) fetches the GitHub PAT
# from this param at runtime — without it, git auth silently stays unset.
data "aws_iam_policy_document" "github_token" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.github_token_parameter}"]
  }
}

resource "aws_iam_role_policy" "github_token" {
  name   = "${var.name_prefix}-github-token"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.github_token.json
}

data "aws_iam_policy_document" "app_bundle" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.app_bundle_arn}/app/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.app_bundle_arn]
  }
}

resource "aws_iam_role_policy" "app_bundle" {
  name   = "${var.name_prefix}-app-bundle"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.app_bundle.json
}

# SSM session streaming (issue #54): the Session document ships shell
# output to the monitoring log group, so the instance role needs write
# access to it. Scoped to that group ARN (passed in from the root
# stack); the broad CloudWatchAgentServerPolicy is not relied upon.
data "aws_iam_policy_document" "ssm_session_logging" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${var.ssm_sessions_log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "ssm_session_logging" {
  name   = "${var.name_prefix}-ssm-session-logging"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.ssm_session_logging.json
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.name_prefix}-profile"
  role = aws_iam_role.server.name
}

resource "aws_key_pair" "server" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

resource "aws_instance" "server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.server.name
  key_name               = var.ssh_public_key != "" ? aws_key_pair.server[0].key_name : null
  # v6 defaults this to false (in-place update that never re-runs user_data);
  # this server is cattle: bootstrap changes must replace it.
  user_data_replace_on_change = true
  # AMI predictability (issue #43, ADR-0029): the AL2023 lookup drifts
  # every 1-2 weeks; without this, each release would replace prod
  # unannounced. Lookup drift is ignored; deliberate rotation flips
  # host_replace_trigger (or pins ami_id AND flips the trigger).
  # replace_triggered_by takes resources only, so the trigger value
  # rides terraform_data (builtin, no provider).
  lifecycle {
    ignore_changes       = [ami]
    replace_triggered_by = [terraform_data.host_replace]
  }
  user_data = templatefile("${path.module}/user_data.sh", {
    name_prefix                   = var.name_prefix
    aws_region                    = var.aws_region
    opencode_password_parameter   = var.opencode_password_parameter
    github_oauth_client_id        = var.github_oauth_client_id
    github_oauth_user             = var.github_oauth_user
    github_oauth_secret_parameter = var.github_oauth_secret_parameter
    oauth_cookie_secret_parameter = var.oauth_cookie_secret_parameter
    provider_api_key_parameters   = var.provider_api_key_parameters
    domain_name                   = var.domain_name
    data_volume_id                = aws_ebs_volume.data.id
    git_user_name                 = var.git_user_name
    git_user_email                = var.git_user_email
    github_token_parameter        = var.github_token_parameter
    app_bundle_bucket             = var.app_bundle_bucket
    deployed_version              = var.deployed_version
  })

  # IMDSv2 only: arbitrary agent code runs with docker.sock mounted, so
  # unauthenticated IMDSv1 is an SSRF credential-theft path. Containers
  # never need IMDS (AWS access flows through the instance role).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.name_prefix}-server"
    DeployedRef = var.deployed_version
  }
}

# Standalone EIP with a separate association: the address must survive
# instance replacement AND targeted full-rebuild destroys. An inline
# `instance` argument would make the EIP depend on the instance, so a
# targeted destroy of the instance pulls the EIP in with it (proven
# 2026-09-12: the first rebuild-prod run released 54.170.161.9 despite
# excluding the EIP from -target). The association resource carries the
# dependency instead, so excluding both from a destroy still leaves the
# address allocated.
resource "aws_eip" "server" {
  domain = "vpc"

  tags = { Name = "${var.name_prefix}-eip" }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id
}

# Persistent data disk (ADR-0008): mounted at /var/lib/docker so containers,
# images, sessions, and certs survive instance replacement. Deliberately NOT
# prevent_destroy (that would break teardown); rule: never destroy without
# explicit user confirmation.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.name_prefix}-data"
    DeployedRef = var.deployed_version
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.server.id
  # Clean detach (issue #46): the old instance is being terminated
  # anyway — stop it first so the OS unmounts /var/lib/docker instead
  # of tearing a mounted ext4 out from under running containers.
  stop_instance_before_detaching = true
}

# Data-disk backup (issue #46, ADR-0030): daily DLM snapshots of the
# persistent volume (tag-targeted), keep 7. Zero daemons, no host IAM,
# cents/month. The execution role is DLM's service-linked role, which
# AWS provisions automatically on first policy creation — managing it
# in Terraform fails (no SLR template for the DLM prefix), so only the
# policy itself is managed here.
resource "aws_dlm_lifecycle_policy" "data" {
  count              = var.enable_data_snapshots ? 1 : 0
  description        = "${var.name_prefix}-data daily snapshots"
  state              = "ENABLED"
  execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/dlm.amazonaws.com/AWSServiceRoleForSnapshotLifecycleManagement"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = "${var.name_prefix}-data"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }
}
