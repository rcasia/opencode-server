output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.server.id
}

output "public_ip" {
  description = "Elastic IP for the server"
  value       = aws_eip.server.public_ip
}
