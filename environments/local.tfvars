# Fully local deploy target (Moto server). No AWS credentials needed.
#   make local-up && make plan-local && make apply-local && make destroy-local
# NOTE: ami_id is intentionally unset here. `make local-up` registers a
# placeholder AMI in Moto and writes its ID to local.auto.tfvars.json
# (generated, gitignored), because Moto only boots registered images.
aws_region        = "eu-west-1"
project           = "opencode"
environment       = "local"
aws_endpoint_url  = "http://localhost:5000"
availability_zone = "eu-west-1a"
instance_type     = "t3.micro"
allowed_ssh_cidr  = "0.0.0.0/0"
ssh_public_key    = ""
root_volume_size  = 30
