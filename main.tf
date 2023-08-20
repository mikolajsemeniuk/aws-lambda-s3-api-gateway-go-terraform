terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                   = var.region
  shared_credentials_files = ["./credentials"]
  profile                  = "default"
}

variable "region" {
  description = "The AWS region"
  default     = "eu-central-1"
}

variable "retention" {
  description = "retention of cloudwatch logs in days"
  default     = 7
}

variable "prefix" {
  default = "logs/"
}

# Binary bucket
resource "aws_s3_bucket" "binary_bucket" {
  bucket = "my-example-binary-bucket-for-lambda"
}

resource "aws_s3_bucket_versioning" "versioning_example" {
  bucket = aws_s3_bucket.binary_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "binary_object" {
  bucket = aws_s3_bucket.binary_bucket.bucket
  key    = "main.zip"
  source = "./main.zip"
  acl    = "private"
}

# Log bucket
resource "aws_s3_bucket" "log_bucket" {
  bucket = "my-example-log-bucket-for-lambda"
}

resource "aws_s3_bucket_logging" "example" {
  bucket = aws_s3_bucket.binary_bucket.id

  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = var.prefix
}

resource "aws_s3_object" "folder" {
  bucket = aws_s3_bucket.log_bucket.bucket
  key    = var.prefix
  source = "/dev/null"
}

resource "aws_s3_bucket_policy" "log_bucket_policy" {
  bucket = aws_s3_bucket.log_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "logging.s3.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.log_bucket.arn}/${var.prefix}*",
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "example" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    id     = "LogCleanup"
    status = "Enabled"
    expiration {
      days = 7
    }
  }
}

# Lambda
resource "aws_lambda_function" "example_lambda" {
  s3_key        = aws_s3_object.binary_object.key
  s3_bucket     = aws_s3_bucket.binary_bucket.bucket
  function_name = "aws_go_lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "main"
  runtime       = "go1.x"

  environment {
    variables = {
      environment = "development"
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "aws_go_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_logs_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/aws_go_lambda"
  retention_in_days = var.retention
}

# API Gateway
resource "aws_apigatewayv2_api" "example_api" {
  name          = "example-api-gateway"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.example_api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.example_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "example_route" {
  api_id    = aws_apigatewayv2_api.example_api.id
  route_key = "GET /lambda"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.example_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_log_group.arn
    format          = "$context.identity.sourceIp - - [$context.requestTime] \"$context.httpMethod $context.routeKey $context.protocol\" $context.status $context.responseLength $context.requestId"
  }

  default_route_settings {
    logging_level = "INFO"
    # Total requests at spike
    throttling_burst_limit = 5000
    # Requests per second
    throttling_rate_limit = 10000
  }
}

resource "aws_lambda_permission" "apigw_lambda_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.example_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_stage.default_stage.execution_arn}/*/*"
}

resource "aws_iam_role" "apigateway_role" {
  name = "apigateway-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apigateway_cloudwatch_logs_policy" {
  role       = aws_iam_role.apigateway_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_cloudwatch_log_group" "api_gateway_log_group" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.example_api.name}"
  retention_in_days = var.retention
}

output "api_gateway_invoke_url" {
  value       = "https://${aws_apigatewayv2_api.example_api.id}.execute-api.${var.region}.amazonaws.com/"
  description = "The URL to invoke the API Gateway"
}
