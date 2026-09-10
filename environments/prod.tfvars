# Production deploy target. Ships automatically on push to main once the
# check jobs are green (deploy-prod node in the ci workflow).
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "prod"
instance_type    = "t3.micro"
allowed_ssh_cidr = "88.148.42.240/32"
ssh_public_key   = "" # optional: "ssh-ed25519 AAAA..."
root_volume_size = 30
domain_name      = "54-170-161-9.nip.io" # wildcard DNS for the EIP; Caddy gets Let's Encrypt TLS for it
alert_email      = ""                    # TODO: your email for intrusion alarms (confirm the SNS subscription email)
