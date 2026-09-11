# Backend config for fully local deploys (Moto server S3). Committed on
# purpose: test-only credentials and a localhost endpoint, no secrets.
# Used by: make plan-local / make apply-local / CI local job.
bucket                      = "opencode-local-tfstate"
key                         = "opencode-server/local/terraform.tfstate"
region                      = "eu-west-1"
encrypt                     = false
use_lockfile                = false
access_key                  = "test"
secret_key                  = "test" # pragma: allowlist secret -- Moto-local dummy credential, committed on purpose (see header)
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
use_path_style              = true
endpoints = {
  s3  = "http://localhost:5000"
  sts = "http://localhost:5000"
  iam = "http://localhost:5000"
}
