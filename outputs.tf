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

output "opencode_url" {
  description = "Public opencode web URL (requires domain_name + DNS A record to the EIP)"
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "no domain_name set — Caddy not configured"
}

output "deployed_version" {
  description = "Version ref of the applied configuration (commit SHA from the pipeline)"
  value       = var.deployed_version
}
