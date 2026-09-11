# Production deploy target. Ships automatically on push to main once the
# check jobs are green (deploy-prod node in the ci workflow).
aws_region       = "eu-west-1"
project          = "opencode"
environment      = "prod"
instance_type    = "t3.small" # 2 vCPU / 2 GB: micro OOMed under real use; +~$7.60/mo
allowed_ssh_cidr = "88.148.42.240/32"
ssh_public_key   = "" # optional: "ssh-ed25519 AAAA..."
root_volume_size = 30
domain_name      = "54-170-161-9.nip.io" # wildcard DNS for the EIP; Caddy gets Let's Encrypt TLS for it
alert_email      = ""                    # set via ALERT_EMAIL Actions variable (TF_VAR_ wins)
git_user_name    = "rcasia"
git_user_email   = "31012661+rcasia@users.noreply.github.com"
# SSO human gate (ADR-0014): GitHub OAuth App client ID (public) + the one
# allowed username. Fill client_id from the OAuth App before pushing —
# empty means oauth2-proxy fails closed (loud, not silent).
github_oauth_client_id = "Ov23li57p6MCRSAeOaFy"
github_oauth_user      = "rcasia"
