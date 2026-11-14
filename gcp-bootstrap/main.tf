# Lab 9, Part 0: what HCP Terraform needs before it can touch the GCP project.
# Run once from the laptop with your own Google sign-in, never from CI:
#
#   gcloud auth application-default login
#   terraform -chdir=gcp-bootstrap init
#   terraform -chdir=gcp-bootstrap apply -var project_id=spry-yulia-2026
#
# It creates: the Workload Identity pool and an OIDC provider for HCP Terraform,
# a "terraform" service account that runs may impersonate, and the spry-gcp
# workspace with the dynamic-credential variables. No JSON key is created,
# anywhere. State is local and git-ignored, like infra-bootstrap/ in Lab 7.

terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.60"
    }
  }
}

variable "project_id" {
  type    = string
  default = "spry-yulia-2026"
}

variable "tfc_organization" {
  type    = string
  default = "ooad-yuliadovhai"
}

variable "workspace" {
  type    = string
  default = "spry-gcp"
}

provider "google" {
  project = var.project_id
}

data "google_project" "this" {}

resource "google_project_service" "bootstrap" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "tfc" {
  workload_identity_pool_id = "hcp-terraform"
  display_name              = "HCP Terraform"
  depends_on                = [google_project_service.bootstrap]
}

# Only runs of this organization's spry-gcp workspace get through.
resource "google_iam_workload_identity_pool_provider" "tfc" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.tfc.workload_identity_pool_id
  workload_identity_pool_provider_id = "app-terraform-io"
  display_name                       = "app.terraform.io"

  oidc {
    issuer_uri = "https://app.terraform.io"
  }

  attribute_mapping = {
    "google.subject"                        = "assertion.sub"
    "attribute.terraform_organization_name" = "assertion.terraform_organization_name"
    "attribute.terraform_workspace_name"    = "assertion.terraform_workspace_name"
  }

  attribute_condition = "assertion.terraform_organization_name == '${var.tfc_organization}' && assertion.terraform_workspace_name == '${var.workspace}'"
}

resource "google_service_account" "terraform" {
  account_id   = "terraform"
  display_name = "Terraform (HCP Terraform runs of ${var.workspace})"
}

# Exactly the roles the lab lists - no Owner, no Editor.
resource "google_project_iam_member" "terraform" {
  for_each = toset([
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform.email}"
}

resource "google_service_account_iam_member" "tfc_impersonates" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.tfc.name}/*"
}

# ---------------------------------------------------------------- the workspace
provider "tfe" {
  organization = var.tfc_organization
}

resource "tfe_workspace" "gcp" {
  name              = var.workspace
  working_directory = "gcp"
  auto_apply        = false
  queue_all_runs    = false
  description       = "Spry on Google Cloud (Lab 9). Separate state from spry-dev."
}

resource "tfe_variable" "gcp_auth" {
  workspace_id = tfe_workspace.gcp.id
  category     = "env"
  key          = "TFC_GCP_PROVIDER_AUTH"
  value        = "true"
}

resource "tfe_variable" "gcp_sa" {
  workspace_id = tfe_workspace.gcp.id
  category     = "env"
  key          = "TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL"
  value        = google_service_account.terraform.email
}

resource "tfe_variable" "gcp_provider" {
  workspace_id = tfe_workspace.gcp.id
  category     = "env"
  key          = "TFC_GCP_WORKLOAD_PROVIDER_NAME"
  value        = google_iam_workload_identity_pool_provider.tfc.name
}

resource "tfe_variable" "project_id" {
  workspace_id = tfe_workspace.gcp.id
  category     = "terraform"
  key          = "project_id"
  value        = var.project_id
}

output "terraform_service_account" {
  value = google_service_account.terraform.email
}

output "workload_provider" {
  value = google_iam_workload_identity_pool_provider.tfc.name
}
