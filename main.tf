module "network" {
  source = "./modules/network"

  name_prefix       = local.name_prefix
  availability_zone = local.availability_zone
  allowed_ssh_cidr  = var.allowed_ssh_cidr
  ssh_public_key    = var.ssh_public_key
}

module "compute" {
  source = "./modules/compute"

  name_prefix                   = local.name_prefix
  ami_id                        = local.ami_id
  instance_type                 = var.instance_type
  subnet_id                     = module.network.public_subnet_id
  security_group_id             = module.network.security_group_id
  availability_zone             = local.availability_zone
  deployed_version              = var.deployed_version
  ssh_public_key                = var.ssh_public_key
  root_volume_size              = var.root_volume_size
  aws_region                    = var.aws_region
  opencode_password_parameter   = var.opencode_password_parameter
  github_oauth_client_id        = var.github_oauth_client_id
  github_oauth_user             = var.github_oauth_user
  github_oauth_secret_parameter = var.github_oauth_secret_parameter
  oauth_cookie_secret_parameter = var.oauth_cookie_secret_parameter
  provider_api_key_parameters   = var.provider_api_key_parameters
  domain_name                   = var.domain_name
  git_user_name                 = var.git_user_name
  git_user_email                = var.git_user_email
  github_token_parameter        = var.github_token_parameter
  app_bundle_bucket             = aws_s3_bucket.app_bundle.bucket
  app_bundle_arn                = aws_s3_bucket.app_bundle.arn
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix = local.name_prefix
  alert_email = var.alert_email
  domain_name = var.domain_name
  instance_id = module.compute.instance_id
}
