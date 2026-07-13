terraform {
  backend "gcs" {
    bucket = "research-502304-tfstate"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.33.0"
    }
  }
}

provider "google" {
  project = var.project_id
}