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

resource "aws_s3_bucket" "binary_bucket" {
  bucket = "my-example-binary-bucket-for-lambda" # You should choose a unique name for this
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

resource "aws_iam_role_policy" "lambda_s3_access" {
  name = "LambdaS3AccessPolicy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action   = ["s3:GetObject"],
      Effect   = "Allow",
      Resource = "${aws_s3_bucket.binary_bucket.arn}/*"
    }]
  })
}

resource "aws_lambda_function" "example_lambda" {
  s3_bucket = aws_s3_bucket.binary_bucket.bucket
  s3_key    = aws_s3_object.binary_object.key

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

resource "aws_apigatewayv2_api" "example_api" {
  name          = "example-api-gateway"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "example_lambda_integration" {
  api_id                 = aws_apigatewayv2_api.example_api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.example_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "example_route" {
  api_id    = aws_apigatewayv2_api.example_api.id
  route_key = "GET /lambda"
  target    = "integrations/${aws_apigatewayv2_integration.example_lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.example_api.id
  name        = "$default"
  auto_deploy = true

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

output "api_gateway_invoke_url" {
  value       = "https://${aws_apigatewayv2_api.example_api.id}.execute-api.${var.region}.amazonaws.com/"
  description = "The URL to invoke the API Gateway"
}
