# Deploy trust (pipeline-applied bootstrap; see ADR-0012, ADR-0013).
#
# The root stack runs AS aws_iam_role.deploy via GitHub OIDC, so these
# policies must allow everything the root stack manages plus what the CI
# steps call directly (bundle upload, ec2 wait, SSM blue-green switch).
# The role manages its own trust (DeploySelf + DeployOIDC) so the
# pipeline converges without a laptop. Missing permission = red deploy,
# fixed here in versioned code — never console clicks.
#
# One IAM policy caps at 6144 bytes, so the trust is split into four
# scoped policies (compute / data / identity / observe), each well under
# the limit. Statements keep explicit action lists (no service-wide `*`).

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
  # Immutable EMU subject: GitHub issues the sub claim with numeric
  # org/repo IDs, NOT the human-readable slug. A slug pattern here
  # matches nothing and locks the pipeline out (proven 2026-09-11:
  # a loose replacement broke AssumeRole for every job).
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [var.deploy_subject]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = [var.deploy_ref]
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
  description        = "GitHub Actions deploys for opencode-server (OIDC)"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

locals {
  state_bucket_pattern  = "${var.project}-${var.environment}-tfstate-*"
  bundle_bucket_pattern = "${var.project}-${var.environment}-app-bundle-*"
  audit_bucket_pattern  = "${var.project}-${var.environment}-audit-*"
}

# EC2 + networking: reads are wildcard by API design; management is an
# explicit action list (no ec2:*).
data "aws_iam_policy_document" "deploy_compute" {
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
      "ec2:CreateFlowLogs",
      "ec2:DeleteFlowLogs",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy_compute" {
  name   = "${var.project}-server-deploy-compute"
  policy = data.aws_iam_policy_document.deploy_compute.json
}

resource "aws_iam_role_policy_attachment" "deploy_compute" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy_compute.arn
}

# State backend + app bundle buckets: full lifecycle (bootstrap and
# bundle.tf manage the buckets themselves; CI up/downloads app/*).
# Read bundle included: the provider refreshes buckets via GetBucket*
# calls, and missing reads fail imports as 409s on re-create.
data "aws_iam_policy_document" "deploy_data" {
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

  statement {
    sid = "BundleBucket"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
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
    sid = "StateBucket"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
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

  statement {
    sid       = "S3ListAll"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # Audit-trail bucket (modules/monitoring): action set mirrors the
  # bundle/state bucket statements, including the TLS-policy, logging,
  # and lifecycle writes the trail bucket resources converge.
  statement {
    sid = "AuditBucket"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
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
    resources = ["arn:aws:s3:::${local.audit_bucket_pattern}"]
  }
}

resource "aws_iam_policy" "deploy_data" {
  name   = "${var.project}-server-deploy-data"
  policy = data.aws_iam_policy_document.deploy_data.json
}

resource "aws_iam_role_policy_attachment" "deploy_data" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy_data.arn
}

# IAM lifecycle: the server role/profile (modules/compute) plus the
# deploy trust itself (DeploySelf + DeployOIDC), so the pipeline
# converges without a laptop.
data "aws_iam_policy_document" "deploy_identity" {
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
      "arn:aws:iam::*:policy/${var.project}-server-deploy*",
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

  statement {
    sid       = "Identity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Flow-logs delivery role (modules/network): same management shape as
  # the server role, scoped to the flow-logs name, plus PassRole to the
  # flow-logs service so aws_flow_log converges.
  statement {
    sid = "FlowLogsRole"
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
    resources = ["arn:aws:iam::*:role/${var.project}-*-flow-logs"]
  }

  statement {
    sid       = "PassFlowLogsRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.project}-*-flow-logs"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "deploy_identity" {
  name   = "${var.project}-server-deploy-identity"
  policy = data.aws_iam_policy_document.deploy_identity.json
}

resource "aws_iam_role_policy_attachment" "deploy_identity" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy_identity.arn
}

# Intrusion alerting + uptime (modules/monitoring) and the blue-green app
# switch (deploy-app): SSM RunShellScript on the server.
data "aws_iam_policy_document" "deploy_observe" {
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
    sid = "Budget"
    actions = [
      "budgets:ViewBudget",
      "budgets:ModifyBudget",
    ]
    resources = ["arn:aws:budgets::*:budget/${var.project}-*"]
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

  # Account audit trail (modules/monitoring): mutating calls scope to the
  # project trail ARN. Reads stay wildcard: CloudTrail list/describe calls
  # do not authorize against the trail ARN (a scoped DescribeTrails still
  # denies with "no identity-based policy allows"), same reads-are-wildcard
  # shape as ComputeRead above.
  statement {
    sid = "Trail"
    actions = [
      "cloudtrail:CreateTrail",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:StartLogging",
      "cloudtrail:StopLogging",
      "cloudtrail:AddTags",
      "cloudtrail:RemoveTags",
    ]
    resources = ["arn:aws:cloudtrail:${var.aws_region}:*:trail/${var.project}-*"]
  }

  statement {
    sid = "TrailRead"
    actions = [
      "cloudtrail:GetTrail",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:DescribeTrails",
      "cloudtrail:ListTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy_observe" {
  name   = "${var.project}-server-deploy-observe"
  policy = data.aws_iam_policy_document.deploy_observe.json
}

resource "aws_iam_role_policy_attachment" "deploy_observe" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy_observe.arn
}
