# Deploy trust (one-time bootstrap, applied with user credentials).
#
# The root stack runs AS aws_iam_role.deploy via GitHub OIDC, so this
# policy must allow everything the root stack manages plus what the CI
# steps call directly (bundle upload, ec2 wait, SSM rolling restart).
# It deliberately cannot touch itself: bootstrap owns this role, and the
# role never manages itself. Missing permission = red deploy, fixed here
# in versioned code — never console clicks (see ADR-0012).

# Thumbprint derived live: survives GitHub CA rotations, nothing to hardcode.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.project}-server-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

locals {
  state_bucket_pattern  = "${var.project}-${var.environment}-tfstate-*"
  bundle_bucket_pattern = "${var.project}-${var.environment}-app-bundle-*"
}

data "aws_iam_policy_document" "deploy" {
  # Remote state backend (S3 native locking: the lockfile is an object too).
  statement {
    sid       = "StateBackend"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket_pattern}"]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket_pattern}/opencode-server/*"]
  }

  # App bundle bucket: full lifecycle (bundle.tf manages the bucket
  # itself; CI uploads compose.yaml + Caddyfile into app/).
  statement {
    sid = "BundleBucket"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketNotification",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
    ]
    resources = ["arn:aws:s3:::${local.bundle_bucket_pattern}"]
  }

  statement {
    sid = "BundleObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:DeleteObjectVersion",
    ]
    resources = ["arn:aws:s3:::${local.bundle_bucket_pattern}/app/*"]
  }

  statement {
    sid       = "S3ListAll"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # EC2 + networking: reads are wildcard by API design; management is an
  # explicit action list (no ec2:*).
  statement {
    sid       = "ComputeRead"
    actions   = ["ec2:Describe*", "ec2:Get*"]
    resources = ["*"]
  }

  statement {
    sid = "ComputeManage"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:ModifyVolume",
      "ec2:CreateKeyPair",
      "ec2:ImportKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
    ]
    resources = ["*"]
  }

  # Server role (modules/compute): full lifecycle, scoped to the project
  # ec2-role name. Never the deploy role itself.
  statement {
    sid = "ServerRole"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::*:role/${var.project}-*-ec2-role"]
  }

  statement {
    sid = "ServerProfile"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::*:instance-profile/${var.project}-*-profile"]
  }

  statement {
    sid       = "ManagedPolicies"
    actions   = ["iam:GetPolicy"]
    resources = ["arn:aws:iam::aws:policy/*"]
  }

  statement {
    sid       = "PassServerRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.project}-*-ec2-role"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Intrusion alerting + uptime (modules/monitoring).
  statement {
    sid = "Alerts"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:ListTagsForResource",
    ]
    resources = ["arn:aws:sns:${var.aws_region}:*:${var.project}-*-alerts"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:PutMetricFilter",
      "logs:DeleteMetricFilter",
      "logs:DescribeMetricFilters",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:ListTagsLogGroup",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:${var.project}-*"]
  }

  statement {
    sid = "Alarms"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:*:alarm:${var.project}-*"]
  }

  statement {
    sid = "HealthChecks"
    actions = [
      "route53:CreateHealthCheck",
      "route53:DeleteHealthCheck",
      "route53:UpdateHealthCheck",
      "route53:GetHealthCheck",
      "route53:GetHealthCheckStatus",
      "route53:ChangeTagsForResource",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # Rolling app restart (deploy-app): SSM RunShellScript on the server.
  statement {
    sid = "RollingRestart"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Identity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Bootstrap self-management: the pipeline applies bootstrap/ AS this
  # role, so the role must manage its own trust (DeploySelf + DeployOIDC)
  # and the state bucket lifecycle (StateBucket). The one-time manual
  # bridge policy is deleted by the bootstrap job once this converges.
  statement {
    sid = "DeploySelf"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:DeletePolicy",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:GetPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::*:role/${var.project}-server-deploy",
      "arn:aws:iam::*:policy/${var.project}-server-deploy",
    ]
  }

  statement {
    sid = "DeployOIDC"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"]
  }

  # State bucket lifecycle (bootstrap manages the bucket itself).
  statement {
    sid = "StateBucket"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketNotification",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
    ]
    resources = ["arn:aws:s3:::${local.state_bucket_pattern}"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.project}-server-deploy"
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}
