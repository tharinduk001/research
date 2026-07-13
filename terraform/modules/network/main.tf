variable "vpc_name" {}
variable "subnet_name" {}
variable "subnet_cidr" {}
variable "region" {}

resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr
  region        = var.region
}

resource "google_compute_firewall" "allow-icmp" {
  name          = "${var.vpc_name}-allow-icmp"
  network       = google_compute_network.vpc.id
  source_ranges = ["0.0.0.0/0"]
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "allow-ssh" {
  name          = "${var.vpc_name}-allow-ssh"
  network       = google_compute_network.vpc.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow-http" {
  name          = "${var.vpc_name}-allow-http"
  network       = google_compute_network.vpc.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_firewall" "allow-https" {
  name          = "${var.vpc_name}-allow-https"
  network       = google_compute_network.vpc.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

output "vpc_name"    { value = google_compute_network.vpc.name }
output "subnet_name" { value = google_compute_subnetwork.subnet.name }