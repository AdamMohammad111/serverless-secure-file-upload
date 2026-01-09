terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

# IMPORTANT:
# Your existing project bucket in AWS was "securestorageforproject".
# If you want Terraform to create a new bucket, set a globally-unique name.
variable "bucket_name" {
  type    = string
  default = "securestorageforproject"
}

# Email that receives SNS notifications (you must confirm the subscription email after apply)
variable "notification_email" {
  type = string
}

data "aws_caller_identity" "current" {}

############################
# DynamoDB (must match code)
############################
resource "aws_dynamodb_table" "audit_logs" {
  name         = "FileAuditLogs" # MUST match your lambda code
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "filename"
  range_key    = "upload_time"

  attribute {
    name = "filename"
    type = "S"
  }

  attribute {
    name = "upload_time"
    type = "S"
  }
}

############################
# SNS (must match code)
############################
resource "aws_sns_topic" "upload_alerts" {
  name = "FileUploadAlerts" # MUST match your hardcoded ARN topic name
}

resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.upload_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# Allow S3 to publish to SNS (optional, but nice if you later want S3->SNS directly)
resource "aws_sns_topic_policy" "allow_s3_publish" {
  arn = aws_sns_topic.upload_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowS3Publish"
      Effect = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action   = "SNS:Publish"
      Resource = aws_sns_topic.upload_alerts.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.secure_storage.arn }
      }
    }]
  })
}

############################
# S3 Bucket
############################
resource "aws_s3_bucket" "secure_storage" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "block_public" {
  bucket                  = aws_s3_bucket.secure_storage.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Default encryption SSE-S3 (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "sse" {
  bucket = aws_s3_bucket.secure_storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CORS: allow browser PUT to presigned URL + allow GET for checking
resource "aws_s3_bucket_cors_configuration" "cors" {
  bucket = aws_s3_bucket.secure_storage.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag", "x-amz-request-id", "x-amz-id-2"]
    max_age_seconds = 3000
  }
}

############################
# IAM for Lambdas
############################
resource "aws_iam_role" "lambda_role" {
  name = "ServerlessProjectLambdaRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "ServerlessProjectLambdaPolicy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 (GenerateUploadLink signs put_object, S3-Audit-Logger reads event)
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = "${aws_s3_bucket.secure_storage.arn}/*"
      },
      # DynamoDB (Audit + List)
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.audit_logs.arn
      },
      # SNS publish (Audit logger sends email)
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.upload_alerts.arn
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

############################
# Package Lambdas (zip)
############################
data "archive_file" "zip_generate" {
  type        = "zip"
  source_file = "${path.module}/lambdas/GenerateUploadLink/lambda_function.py"
  output_path = "${path.module}/GenerateUploadLink.zip"
}

data "archive_file" "zip_audit" {
  type        = "zip"
  source_file = "${path.module}/lambdas/S3-Audit-Logger/lambda_function.py"
  output_path = "${path.module}/S3-Audit-Logger.zip"
}

data "archive_file" "zip_list" {
  type        = "zip"
  source_file = "${path.module}/lambdas/ListAuditLogs/lambda_function.py"
  output_path = "${path.module}/ListAuditLogs.zip"
}

############################
# Lambda Functions (3)
############################
resource "aws_lambda_function" "generate_upload_link" {
  function_name = "GenerateUploadLink"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.zip_generate.output_path
  source_code_hash = data.archive_file.zip_generate.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.secure_storage.bucket # MUST exist for your code
    }
  }
}

resource "aws_lambda_function" "s3_audit_logger" {
  function_name = "S3-Audit-Logger"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.zip_audit.output_path
  source_code_hash = data.archive_file.zip_audit.output_base64sha256
}

resource "aws_lambda_function" "list_audit_logs" {
  function_name = "ListAuditLogs"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.zip_list.output_path
  source_code_hash = data.archive_file.zip_list.output_base64sha256
}

############################
# API Gateway (REST)
############################
resource "aws_api_gateway_rest_api" "api" {
  name = "SecureFileAPI"
}

resource "aws_api_gateway_resource" "get_link" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "get-link"
}

resource "aws_api_gateway_resource" "list" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "list"
}

# GET /get-link
resource "aws_api_gateway_method" "get_link_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.get_link.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_link_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.get_link.id
  http_method             = aws_api_gateway_method.get_link_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.generate_upload_link.invoke_arn
}

# GET /list
resource "aws_api_gateway_method" "list_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.list.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "list_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.list.id
  http_method             = aws_api_gateway_method.list_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.list_audit_logs.invoke_arn
}

# CORS for /get-link
resource "aws_api_gateway_method" "get_link_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.get_link.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_link_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.get_link.id
  http_method = aws_api_gateway_method.get_link_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "get_link_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.get_link.id
  http_method = aws_api_gateway_method.get_link_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
  }
}

resource "aws_api_gateway_integration_response" "get_link_options_integration_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.get_link.id
  http_method = aws_api_gateway_method.get_link_options.http_method
  status_code = aws_api_gateway_method_response.get_link_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
  }
  depends_on = [aws_api_gateway_integration.get_link_options_integration]
}

# CORS for /list
resource "aws_api_gateway_method" "list_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.list.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "list_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "list_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
  }
}

resource "aws_api_gateway_integration_response" "list_options_integration_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  status_code = aws_api_gateway_method_response.list_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
  }
  depends_on = [aws_api_gateway_integration.list_options_integration]
}

# Deploy
resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_integration.get_link_integration.id,
      aws_api_gateway_integration.list_integration.id,
      aws_api_gateway_integration_response.get_link_options_integration_200.id,
      aws_api_gateway_integration_response.list_options_integration_200.id
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.get_link_integration,
    aws_api_gateway_integration.list_integration,
    aws_api_gateway_integration_response.get_link_options_integration_200,
    aws_api_gateway_integration_response.list_options_integration_200
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = "prod"
}

############################
# Permissions: API Gateway -> Lambda
############################
resource "aws_lambda_permission" "allow_apigw_get_link" {
  statement_id  = "AllowAPIGWInvokeGenerateUploadLink"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generate_upload_link.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "allow_apigw_list" {
  statement_id  = "AllowAPIGWInvokeListAuditLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.list_audit_logs.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

############################
# S3 -> Lambda trigger (Audit Logger)
############################
resource "aws_lambda_permission" "allow_s3_invoke_audit" {
  statement_id  = "AllowS3InvokeAuditLogger"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_audit_logger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.secure_storage.arn
}

resource "aws_s3_bucket_notification" "s3_notifications" {
  bucket = aws_s3_bucket.secure_storage.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_audit_logger.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [
    aws_lambda_permission.allow_s3_invoke_audit
  ]
}

############################
# Outputs
############################
output "bucket_name" {
  value = aws_s3_bucket.secure_storage.bucket
}

output "api_base_url" {
  value = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}"
}

output "get_link_url" {
  value = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}/get-link"
}

output "list_url" {
  value = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}/list"
}

output "sns_topic_arn" {
  value = aws_sns_topic.upload_alerts.arn
}
