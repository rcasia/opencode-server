# Production deploy target. Ships automatically on push to main once the
# check jobs are green (deploy-prod node in the ci workflow).
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "prod"
instance_type    = "t3.micro"
allowed_ssh_cidr = "88.148.42.240/32"
ssh_public_key   = "" # optional: "ssh-ed25519 AAAA..."
root_volume_size = 30
opencode_port    = 4096
domain_name      = "" # TODO: set your domain, e.g. "code.example.com" (needs A record -> EIP)
