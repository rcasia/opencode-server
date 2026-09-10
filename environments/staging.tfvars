# staging == local deploy target.
# Deploy from your laptop with:
#   terraform plan -var-file=environments/staging.tfvars
#   terraform apply -var-file=environments/staging.tfvars
# Or: make plan-staging / make apply-staging
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "staging"
instance_type    = "t3.micro"
allowed_ssh_cidr = "0.0.0.0/0" # TODO: restrict to YOUR_IP/32 before apply
ssh_public_key   = ""          # optional: "ssh-ed25519 AAAA..."
root_volume_size = 30
opencode_port    = 4096
