# Lab 9: Spry's core on Google Cloud. Its own HCP Terraform workspace (spry-gcp),
# so one plan can never break both clouds. Credentials come from Workload
# Identity Federation (gcp-bootstrap/), not from a key.
terraform {
  required_version = ">= 1.10"

  cloud {
    organization = "ooad-yuliadovhai"
    workspaces {
      name = "spry-gcp"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    project_name = "spry"
    managed_by   = "terraform"
  }
}
