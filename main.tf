module "network" {
  source = "./modules/network"

  name_prefix       = local.name_prefix
  availability_zone = local.availability_zone
  allowed_ssh_cidr  = var.allowed_ssh_cidr
}

module "compute" {
  source = "./modules/compute"

  name_prefix                 = local.name_prefix
  ami_id                      = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = module.network.public_subnet_id
  security_group_id           = module.network.security_group_id
  availability_zone           = local.availability_zone
  ssh_public_key              = var.ssh_public_key
  root_volume_size            = var.root_volume_size
  aws_region                  = var.aws_region
  opencode_password_parameter = var.opencode_password_parameter
  domain_name                 = var.domain_name
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix = local.name_prefix
  alert_email = var.alert_email
}
