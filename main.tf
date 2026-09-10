module "network" {
  source = "./modules/network"

  name_prefix       = local.name_prefix
  availability_zone = local.availability_zone
  allowed_ssh_cidr  = var.allowed_ssh_cidr
  opencode_port     = var.opencode_port
}

module "compute" {
  source = "./modules/compute"

  name_prefix       = local.name_prefix
  ami_id            = local.ami_id
  instance_type     = var.instance_type
  subnet_id         = module.network.public_subnet_id
  security_group_id = module.network.security_group_id
  ssh_public_key    = var.ssh_public_key
  root_volume_size  = var.root_volume_size
  opencode_port     = var.opencode_port
}
