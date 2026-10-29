terraform {
  required_version = ">= 1.10"

  # State and runs live in HCP Terraform. The workspace and its AWS access are
  # created by infra-bootstrap/ (see the README).
  cloud {
    organization = "ooad-yuliadovhai"

    workspaces {
      name = "spry-dev"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.67 is the first version known to have invoked_via_function_url on
      # aws_lambda_permission (ai.tf).
      version = ">= 6.67, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}
