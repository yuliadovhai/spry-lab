# The one piece that has to exist before HCP Terraform can do anything
# (Lab 7, Part 1, Step 7): an IAM OIDC provider that trusts app.terraform.io,
# the role a run assumes, and the spry-dev workspace with the variables that
# tell its runs to use that role.
#
# Applied once, from a laptop, with your own AWS credentials and the HCP
# Terraform token from `terraform login`. Its state stays local and out of Git
# (.gitignore): it holds no secrets beyond what is printed below.
#
#   make tf-bootstrap BUDGET_EMAIL=you@example.com

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.60"
    }
  }
}

variable "tfc_organization" {
  type    = string
  default = "ooad-yuliadovhai"
}

variable "workspace" {
  type    = string
  default = "spry-dev"
}

variable "project_name" {
  type    = string
  default = "spry"
}

variable "budget_email" {
  type        = string
  description = "Where the $5 budget alarm goes; stored in the workspace, not in Git."
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform-bootstrap"
    }
  }
}

# Reads the token that `terraform login` saved.
provider "tfe" {}

# --- AWS trusts HCP Terraform ------------------------------------------------------

data "tls_certificate" "tfc" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "tfc" {
  name = "hcp-terraform-${var.tfc_organization}"

  # Narrower than the lab's example: one workspace of one organization, any
  # project and run phase. A run of another workspace cannot assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        StringLike = {
          "app.terraform.io:sub" = "organization:${var.tfc_organization}:project:*:workspace:${var.workspace}:run_phase:*"
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to what the workspace
# manages: lambda:*, iam:*Role*, logs:*, ecr:*Repository*, budgets:*.
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- the workspace -----------------------------------------------------------------

resource "tfe_workspace" "spry" {
  name         = var.workspace
  organization = var.tfc_organization
  description  = "Spry infrastructure (infra/), dev environment."

  # The Terraform files live in infra/ of the repository.
  working_directory = "infra"
  # A merge to main is applied without a click; a pull request only plans.
  auto_apply = true
  # Do not start a run the moment the workspace is created.
  queue_all_runs = false
}

resource "tfe_variable" "aws_auth" {
  workspace_id = tfe_workspace.spry.id
  category     = "env"
  key          = "TFC_AWS_PROVIDER_AUTH"
  value        = "true"
  description  = "Dynamic AWS credentials: no stored keys."
}

resource "tfe_variable" "aws_role" {
  workspace_id = tfe_workspace.spry.id
  category     = "env"
  key          = "TFC_AWS_RUN_ROLE_ARN"
  value        = aws_iam_role.tfc.arn
}

resource "tfe_variable" "budget_email" {
  workspace_id = tfe_workspace.spry.id
  category     = "terraform"
  key          = "budget_email"
  value        = var.budget_email
  description  = "Personal data: kept here, not in terraform.tfvars."
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}

output "workspace_url" {
  value = "https://app.terraform.io/app/${var.tfc_organization}/workspaces/${var.workspace}"
}
