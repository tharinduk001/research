variable "cluster_name" {}
variable "zone" {}
variable "node_pool_name" {}
variable "node_count" {}
variable "machine_type" {}
variable "disk_type" {}
variable "disk_size" {}
variable "image_type" {}
variable "vpc_name" {}
variable "subnet_name" {}

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  network    = var.vpc_name
  subnetwork = var.subnet_name

  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }
}

resource "google_container_node_pool" "custom_pool" {
  name     = var.node_pool_name
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    image_type   = var.image_type
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}