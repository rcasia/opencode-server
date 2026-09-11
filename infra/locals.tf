locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Overrides win; otherwise fall back to live lookups.
  availability_zone = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available[0].names[0]
  ami_id            = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023[0].id
}
