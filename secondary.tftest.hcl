mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-northeast-1:123456789012:log-group:/mock" }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = { execution_arn = "arn:aws:execute-api:ap-northeast-1:123456789012:mock-api" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { invoke_arn = "arn:aws:apigateway:ap-northeast-1:lambda:path/2015-03-31/functions/arn:aws:lambda:ap-northeast-1:123456789012:function:mock-function/invocations" }
  }
}
mock_provider "archive" {}
mock_provider "random" {}

variables {
  aws_account_id   = "123456789012"
  google_client_id = "test.apps.googleusercontent.com"
  allowed_email    = "allowed@example.invalid"
}

run "secondary_routing" {
  # All providers are mocked; apply resolves IDs without calling AWS.
  command = apply
  assert {
    condition     = aws_lambda_function.this.filename == data.archive_file.lambda.output_path && aws_lambda_function.secondary.filename == data.archive_file.secondary.output_path && aws_lambda_function.this.filename != aws_lambda_function.secondary.filename && data.archive_file.lambda.source_file != data.archive_file.secondary.source_file
    error_message = "Each Lambda must deploy its own separately built executable and zip."
  }
  assert {
    condition     = aws_apigatewayv2_route.secondary.route_key == "GET /secondary" && aws_apigatewayv2_route.secondary.authorization_type == "CUSTOM" && aws_apigatewayv2_route.secondary.authorizer_id == aws_apigatewayv2_authorizer.google.id
    error_message = "Secondary route must require the first Lambda authorizer."
  }
  assert {
    condition     = aws_apigatewayv2_route.secondary.target == "integrations/${aws_apigatewayv2_integration.secondary.id}" && aws_apigatewayv2_integration.secondary.integration_uri == aws_lambda_function.secondary.invoke_arn && aws_apigatewayv2_integration.secondary.payload_format_version == "2.0"
    error_message = "Secondary route must invoke the separate Lambda using payload 2.0."
  }
  assert {
    condition     = aws_lambda_function.secondary.function_name != aws_lambda_function.this.function_name && aws_lambda_function.secondary.role == aws_iam_role.secondary.arn && length(aws_lambda_function.secondary.environment) == 0
    error_message = "Second Lambda must be distinct, have its own role, and have no authentication configuration."
  }
  assert {
    condition     = aws_lambda_permission.secondary.function_name == aws_lambda_function.secondary.function_name && aws_lambda_permission.secondary.source_arn == "${aws_apigatewayv2_api.this.execution_arn}/*/GET/secondary"
    error_message = "Invoke permission must be limited to the secondary GET route."
  }
  assert {
    condition     = aws_apigatewayv2_route.private.route_key == "ANY /{proxy+}" && aws_apigatewayv2_route.private.target == "integrations/${aws_apigatewayv2_integration.lambda.id}" && aws_apigatewayv2_integration.lambda.integration_uri == aws_lambda_function.this.invoke_arn && aws_apigatewayv2_route.private.authorization_type == "CUSTOM" && aws_apigatewayv2_route.private.authorizer_id == aws_apigatewayv2_authorizer.google.id
    error_message = "Both routes must use the authorizer and /private must invoke the first Lambda integration."
  }
  assert {
    condition     = aws_apigatewayv2_authorizer.google.authorizer_type == "REQUEST" && aws_apigatewayv2_authorizer.google.authorizer_uri == aws_lambda_function.this.invoke_arn && aws_apigatewayv2_authorizer.google.authorizer_payload_format_version == "2.0" && aws_apigatewayv2_authorizer.google.enable_simple_responses && aws_apigatewayv2_authorizer.google.authorizer_result_ttl_in_seconds == 0 && aws_lambda_function.this.environment[0].variables["ALLOWED_EMAIL"] == var.allowed_email && aws_lambda_function.this.environment[0].variables["GOOGLE_CLIENT_ID"] == var.google_client_id
    error_message = "Authentication and authorization must be delegated only to the first Lambda, with decision caching disabled."
  }
  assert {
    condition     = aws_lambda_permission.authorizer.principal == "apigateway.amazonaws.com" && aws_lambda_permission.authorizer.source_arn == "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.google.id}" && aws_lambda_permission.secondary.principal == "apigateway.amazonaws.com" && aws_lambda_permission.secondary.source_account == var.aws_account_id && aws_lambda_permission.primary.function_name == aws_lambda_function.this.function_name && aws_lambda_permission.primary.principal == "apigateway.amazonaws.com" && aws_lambda_permission.primary.source_account == var.aws_account_id && aws_lambda_permission.primary.source_arn == "${aws_apigatewayv2_api.this.execution_arn}/*/*/*"
    error_message = "Resource permissions must be scoped to this API/account, with primary wildcard and secondary GET permissions."
  }

}
