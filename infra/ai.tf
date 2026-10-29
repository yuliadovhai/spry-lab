# The agenda parser from Lab 6, formerly infra/ai.yml.
#
# A Lambda function outside the VPC that turns pasted text into a structured
# agenda with an LLM on Amazon Bedrock, behind its own HTTPS function URL. It
# never writes data: saving goes through the main API.

locals {
  parser_name = "${var.project_name}-agenda-parser"
}

# --- container registry ----------------------------------------------------------

# Created by hand by scripts/deploy-ai.sh in Lab 6, outside any template: the
# kind of resource nobody remembers (Lab 7, Part 0, Step 6). Now it is written down.
resource "aws_ecr_repository" "parser" {
  name                 = local.parser_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

# --- permissions -------------------------------------------------------------------

resource "aws_iam_role" "parser" {
  name = var.parser_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "parser_logs" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parser_bedrock" {
  name = "invoke-bedrock"
  role = aws_iam_role.parser.name

  # "*" for now - narrowing it is one of Lab 6's questions.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock-mantle:CreateInference", "bedrock:InvokeModel"]
      Resource = "*"
    }]
  })
}

# --- the function ------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/aws/lambda/${local.parser_name}"
  retention_in_days = 14
}

# No vpc_config: the parser needs no database, so it reaches Bedrock over the
# internet without a NAT gateway or a VPC endpoint.
resource "aws_lambda_function" "parser" {
  function_name = local.parser_name
  description   = "Pasted text -> structured agenda (suggestion only, never writes)"
  package_type  = "Image"
  image_uri     = var.parser_image_uri
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30
  role          = aws_iam_role.parser.arn

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.parser.name
  }

  environment {
    variables = {
      PARSER_MODEL = var.parser_model
    }
  }

  # Two roads (Lab 7, Step 4): Terraform owns the function's configuration,
  # the application pipeline (make deploy-ai) owns its code. Without this, every
  # plan would try to roll the function back to the image it was created with.
  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = var.allowed_origins
    allow_methods = ["POST"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

# A public function URL needs both statements: InvokeFunctionUrl, and
# InvokeFunction limited to calls that came through the URL. These two are
# created fresh rather than imported - see docs/adr/0007-terraform.md.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "SpryFunctionUrlPublic"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.parser.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_url_invoke" {
  statement_id             = "SpryFunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.parser.function_name
  principal                = "*"
  invoked_via_function_url = true
}

# --- budget ------------------------------------------------------------------------

# The cheapest insurance in the course: an email at 80% spent and 100% forecast.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = format("%.1f", var.budget_usd)
  limit_unit   = "USD"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }
}
