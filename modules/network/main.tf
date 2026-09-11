# Single public subnet + IGW. No NAT gateway by design (cheap).

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "server" {
  name        = "${var.name_prefix}-sg"
  description = "Agentic coding server"
  vpc_id      = aws_vpc.main.id

  # Port 22 exists only in SSH-key mode. SSM-only (empty ssh_public_key)
  # gets no ingress at all, so a default/empty CIDR can never open SSH.
  dynamic "ingress" {
    for_each = var.ssh_public_key != "" ? [var.allowed_ssh_cidr] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  ingress {
    description = "HTTP for Caddy: LE HTTP-01 and redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS for Caddy: opencode web reverse proxy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }

  lifecycle {
    # Cross-variable validation needs Terraform 1.9+, so the key/CIDR
    # pairing is enforced here: SSM-only means no CIDR, a key requires
    # an explicit /32 (never open).
    precondition {
      condition     = var.ssh_public_key == "" ? var.allowed_ssh_cidr == "" : can(regex("/32$", var.allowed_ssh_cidr))
      error_message = "Without ssh_public_key (SSM-only), allowed_ssh_cidr must be empty; with a key, it must be an explicit /32 CIDR, e.g. 1.2.3.4/32. Never 0.0.0.0/0."
    }
  }
}

# VPC Flow Logs (audit ADR): all traffic for the single-host VPC ships to
# CloudWatch with 30-day retention. Cents per month at this volume.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "${var.name_prefix}-vpc-flow-logs"
  retention_in_days = 30
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name_prefix}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = { Name = "${var.name_prefix}-flow-logs" }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    sid       = "WriteFlowLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.name_prefix}-flow-logs"
  role   = aws_iam_role.flow_logs.name
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = { Name = "${var.name_prefix}-flow-logs" }
}
