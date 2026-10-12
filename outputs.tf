output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}
output "google_client_id" {
  value = var.google_client_id
}
output "aws_region" {
  value = var.aws_region
}
output "lambda_log_group" {
  value = aws_cloudwatch_log_group.lambda.name
}
output "api_log_group" {
  value = aws_cloudwatch_log_group.api.name
}
output "lambda_function_name" {
  value = aws_lambda_function.this.function_name
}

output "secondary_lambda_function_name" {
  value = aws_lambda_function.secondary.function_name
}
output "secondary_lambda_log_group" {
  value = aws_cloudwatch_log_group.secondary.name
}
