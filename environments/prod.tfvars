# Production deploy target. Deploys ONLY via the deploy workflow:
#   gh workflow run deploy --ref main -f action=plan
#   gh workflow run deploy --ref main -f action=apply
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "prod"
instance_type    = "t3.micro"
allowed_ssh_cidr = "0.0.0.0/0" # TODO: restrict to YOUR_IP/32 before apply
ssh_public_key   = ""          # optional: "ssh-ed25519 AAAA..."
root_volume_size = 30
opencode_port    = 4096
