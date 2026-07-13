module "network" {
  source = "./modules/network"

  vpc_name    = var.vpc_name
  subnet_name = var.subnet_name
  subnet_cidr = var.subnet_cidr
  region      = var.region
}

module "gke" {
  source = "./modules/gke"

  cluster_name   = var.cluster_name
  zone           = var.zone
  node_pool_name = var.node_pool_name
  node_count     = var.node_count
  machine_type   = var.machine_type
  disk_type      = var.disk_type
  disk_size      = var.disk_size
  image_type     = var.image_type

  vpc_name    = module.network.vpc_name
  subnet_name = module.network.subnet_name

  depends_on = [module.network]
}