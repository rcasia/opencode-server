output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID for the server"
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Server security group ID"
  value       = aws_security_group.server.id
}
