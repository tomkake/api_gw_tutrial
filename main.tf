resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name = "${var.name_prefix}-${random_id.suffix.hex}"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 7
}

resource "aws_iam_role" "lambda" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "logs" {
  name = "write-own-log-streams"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
    }]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/.build/bootstrap"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_lambda_function" "this" {
  function_name    = local.name
  role             = aws_iam_role.lambda.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  environment {
    variables = {
      ALLOWED_EMAIL    = var.allowed_email
      GOOGLE_CLIENT_ID = var.google_client_id
    }
  }
  memory_size = 128
  timeout     = 10
  depends_on  = [aws_iam_role_policy.logs]
}

resource "aws_apigatewayv2_api" "this" {
  name          = local.name
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins  = ["http://localhost:8000"]
    allow_methods  = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    allow_headers  = ["authorization"]
    expose_headers = ["apigw-requestid"]
    max_age        = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "google" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "google-lambda-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.this.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
  identity_sources                  = ["$request.header.Authorization"]
}

resource "aws_apigatewayv2_route" "private" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /{proxy+}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.google.id
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId         = "$context.requestId"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      integrationStatus = "$context.integration.status"
    })
  }
}

resource "aws_lambda_permission" "authorizer" {
  statement_id   = "Allow-authorizer"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.google.id}"
  source_account = var.aws_account_id
}

# A separate Lambda with its own execution role and log group.
resource "aws_cloudwatch_log_group" "secondary" {
  name              = "/aws/lambda/${local.name}-secondary"
  retention_in_days = 7
}

resource "aws_iam_role" "secondary" {
  name = "${local.name}-secondary"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "secondary_logs" {
  name = "write-own-log-streams"
  role = aws_iam_role.secondary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.secondary.arn}:*"
    }]
  })
}

data "archive_file" "secondary" {
  type        = "zip"
  source_file = "${path.module}/.build/secondary/bootstrap"
  output_path = "${path.module}/.build/secondary-lambda.zip"
}

resource "aws_lambda_function" "secondary" {
  function_name    = "${local.name}-secondary"
  role             = aws_iam_role.secondary.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = data.archive_file.secondary.output_path
  source_code_hash = data.archive_file.secondary.output_base64sha256
  memory_size      = 128
  timeout          = 5
  depends_on       = [aws_iam_role_policy.secondary_logs]
}

resource "aws_apigatewayv2_integration" "secondary" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.secondary.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "secondary" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /secondary"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.google.id
  target             = "integrations/${aws_apigatewayv2_integration.secondary.id}"
}

resource "aws_lambda_permission" "secondary" {
  statement_id   = "Allow-secondary"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.secondary.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.this.execution_arn}/*/GET/secondary"
  source_account = var.aws_account_id
}

resource "aws_lambda_permission" "primary" {
  statement_id   = "Allow-primary-routes"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_apigatewayv2_api.this.execution_arn}/*/*/*"
  source_account = var.aws_account_id
}
