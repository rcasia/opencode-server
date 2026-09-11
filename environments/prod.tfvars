# Production deploy target. Ships automatically on push to main once the
# check jobs are green (deploy-prod node in the ci workflow).
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "prod"
instance_type    = "t3.small" # 2 vCPU / 2 GB: micro OOMed under real use; +~$7.60/mo
allowed_ssh_cidr = ""         # SSM-only default. To allow SSH, set your /32 here
# (e.g. 203.0.113.7/32 — never 0.0.0.0/0) or via TF_VAR_allowed_ssh_cidr.
# A literal YOUR_IP/32 placeholder is intentionally NOT used: the variable
# validation rejects non-CIDR values, so it would fail every plan.
ssh_public_key   = "" # optional: "ssh-ed25519 AAAA..." (pair with your /32 in allowed_ssh_cidr)
root_volume_size = 30
domain_name      = "code.example.com" # placeholder; the operator sets the
# real <eip-with-dashes>.nip.io via the DOMAIN_NAME Actions secret
# (TF_VAR_domain_name wins). Never commit a live domain here.
alert_email    = "" # set via ALERT_EMAIL Actions secret (TF_VAR_ wins)
git_user_name  = "" # operator identity via GIT_USER_NAME secret (TF_VAR_ wins)
git_user_email = "" # operator identity via GIT_USER_EMAIL secret (TF_VAR_ wins)
# SSO human gate (ADR-0014): GitHub OAuth App client ID (public) + the one
# allowed username. Both arrive via Actions secrets (TF_VAR_ wins) and fail
# closed when empty — oauth2-proxy denies everyone. Never commit live values.
github_oauth_client_id = ""
github_oauth_user      = ""

# Provider credentials: names only. Values live in SSM SecureStrings and are
# fetched by the instance at boot with xtrace disabled. Empty = disabled.
provider_api_key_parameters = {
  OPENCODE_API_KEY = "/opencode/opencode-api-key"
}
