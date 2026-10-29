variable "project_name" {
  type        = string
  description = "Prefix of every resource name, and the PROJECT_NAME tag."
  default     = "spry"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# --- the agenda parser (Lab 6) -------------------------------------------------

variable "parser_role_name" {
  type        = string
  description = <<-EOT
    The parser's IAM role. CloudFormation generated this name (spry-ai-Role-...),
    and it is kept as it is: a different name would be a new role, not an
    imported one. Written to terraform.tfvars by scripts/tf-adopt.sh.
  EOT
}

variable "parser_image_uri" {
  type        = string
  description = <<-EOT
    The image the function was created with. After that the application
    pipeline (make deploy-ai) owns the code, and Terraform ignores changes to it.
  EOT
}

variable "parser_model" {
  type        = string
  description = "Bedrock model id: anthropic.* uses the Messages API, anything else Converse."
  default     = "us.amazon.nova-micro-v1:0"
}

variable "allowed_origins" {
  type        = list(string)
  description = "Browser origins allowed to call the parser's function URL (CORS)."
}

# --- budget --------------------------------------------------------------------

variable "budget_email" {
  type        = string
  description = <<-EOT
    Where the monthly budget alarm goes. Personal data, so it is not in Git:
    infra-bootstrap/ stores it as a variable of the HCP Terraform workspace.
  EOT
}

variable "budget_usd" {
  type    = number
  default = 5
}
