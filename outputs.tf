output "instance_id" {
  description = "EC2 instance ID"
  value       = module.compute.instance_id
}

output "public_ip" {
  description = "Elastic IP for the server"
  value       = module.compute.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "security_group_id" {
  description = "Security group ID"
  value       = module.network.security_group_id
}

output "ssh_command" {
  description = "SSH command (only if ssh_public_key was set)"
  value       = "ssh -i ~/.ssh/${local.name_prefix}.pem ec2-user@${module.compute.public_ip}"
}

output "ssm_command" {
  description = "Keyless shell via Session Manager"
  value       = "aws sso login --profile <profile> 2>/dev/null; aws ssm start-session --region ${var.aws_region} --target ${module.compute.instance_id}"
}
