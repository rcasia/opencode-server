output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.server.id
}

output "public_ip" {
  description = "Elastic IP for the server"
  value       = aws_eip.server.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.server.id
}

output "ssh_command" {
  description = "SSH command (only if ssh_public_key was set)"
  value       = "ssh -i ~/.ssh/${local.name_prefix}.pem ec2-user@${aws_eip.server.public_ip}"
}

output "ssm_command" {
  description = "Keyless shell via Session Manager"
  value       = "aws sso login --profile <profile> 2>/dev/null; aws ssm start-session --region ${var.aws_region} --target ${aws_instance.server.id}"
}
