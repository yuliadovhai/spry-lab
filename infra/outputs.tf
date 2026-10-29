# Read by the Makefile (make infra-outputs) and, through .env, by the frontend build.

output "parser_url" {
  description = "POST {text, today, tz} here."
  value       = trimsuffix(aws_lambda_function_url.parser.function_url, "/")
}

output "parser_function_name" {
  value = aws_lambda_function.parser.function_name
}

output "parser_repository_url" {
  value = aws_ecr_repository.parser.repository_url
}

output "parser_log_group" {
  value = aws_cloudwatch_log_group.parser.name
}
