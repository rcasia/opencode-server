# Production deploy target. Ships automatically on push to main once the
# check jobs are green (deploy-prod node in the ci workflow).
aws_region  = "eu-west-1"
project     = "opencode"
environment = "prod"
# Pinned, never the available[0] fallback: the data volume lives in this
# AZ and changing it forces the volume's replacement (data loss). Today
# every prod resource is in eu-west-1a, so this pin is a no-op for plan.
availability_zone = "eu-west-1a"
instance_type     = "t3.small" # 2 vCPU / 2 GB: micro OOMed under real use; +~$7.60/mo
allowed_ssh_cidr  = ""         # SSM-only default. To allow SSH, set your /32 here
# (e.g. 203.0.113.7/32 — never 0.0.0.0/0) or via TF_VAR_allowed_ssh_cidr.
# A literal YOUR_IP/32 placeholder is intentionally NOT used: the variable
# validation rejects non-CIDR values, so it would fail every plan.
ssh_public_key   = "" # optional: "ssh-ed25519 AAAA..." (pair with your /32 in allowed_ssh_cidr)
root_volume_size = 30
# Runtime deployment values are supplied by GitHub Actions secrets as TF_VAR_*
# and must not be defined here, otherwise the -var-file values override them.

# Provider credentials: names only. Values live in SSM SecureStrings and are
# fetched by the instance at boot with xtrace disabled. Empty = disabled.
provider_api_key_parameters = {
  OPENCODE_API_KEY = "/opencode/opencode-api-key"
}
