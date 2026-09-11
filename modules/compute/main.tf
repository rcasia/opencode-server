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

resource "aws_iam_role_policy" "oauth_secrets" {
  name   = "${var.name_prefix}-oauth-secrets"
  role   = aws_iam_role.server.name
  policy = data.aws_iam_policy_document.oauth_secrets.json
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
  user_data = templatefile("${path.module}/user_data.sh", {
    name_prefix                   = var.name_prefix
    aws_region                    = var.aws_region
    opencode_password_parameter   = var.opencode_password_parameter
    github_oauth_client_id        = var.github_oauth_client_id
    github_oauth_user             = var.github_oauth_user
    github_oauth_secret_parameter = var.github_oauth_secret_parameter
    oauth_cookie_secret_parameter = var.oauth_cookie_secret_parameter
    domain_name                   = var.domain_name
    data_volume_id                = aws_ebs_volume.data.id
    git_user_name                 = var.git_user_name
    git_user_email                = var.git_user_email
    github_token_parameter        = var.github_token_parameter
    app_bundle_bucket             = var.app_bundle_bucket
  })

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

resource "aws_eip" "server" {
  instance = aws_instance.server.id
  domain   = "vpc"

  tags = { Name = "${var.name_prefix}-eip" }
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
}
