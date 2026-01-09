############################################
# Provider Configuration
############################################
# This project uses AWS in the eu-north-1 region
provider "aws" {
  region = "eu-north-1"
}

############################################
# DynamoDB Table – Audit Logs
############################################
# This table stores metadata about every uploaded file
# (filename + upload_time are used as primary keys)
resource "aws_dynamodb_table" "audit_logs" {
  name         = "FileAuditLogs_Terraform"
  billing_mode = "PAY_PER_REQUEST"

  # Partition key
  hash_key  = "filename"
  # Sort key
  range_key = "upload_time"

  attribute {
    name = "filename"
    type = "S"
  }

  attribute {
    name = "upload_time"
    type = "S"
  }
}

############################################
# S3 Bucket – Secure File Storage
############################################
# This bucket stores uploaded files securely
resource "aws_s3_bucket" "secure_storage" {
  bucket        = "cloud-project-bucket-20220032"
  force_destroy = true
}

############################################
# S3 Bucket Policy – Enforce MFA (with Lambda exception)
############################################
# This policy blocks direct uploads unless MFA is present,
# except when uploads are performed via the Lambda role
resource "aws_s3_bucket_policy" "enforce_mfa_upload" {
  bucket = aws_s3_bucket.secure_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUploadsWithoutMFA"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.secure_storage.arn}/*"
        Condition = {
          Null = {
            "aws:MultiFactorAuthPresent" = "true"
          }
          StringNotLike = {
            "aws:PrincipalArn" = aws_iam_role.lambda_role.arn
          }
        }
      }
    ]
  })
}

############################################
# Package Lambda Code
############################################
# Zips the Lambda handler file before deployment
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "upload_handler.py"
  output_path = "upload_handler.zip"
}

############################################
# IAM Role – Lambda Execution Role
############################################
# Allows Lambda to run and access AWS services
resource "aws_iam_role" "lambda_role" {
  name = "UploadAPIRole_Terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

############################################
# IAM Policy – Lambda Permissions
############################################
# Grants Lambda permission to:
# - Upload objects to S3
# - Write logs to DynamoDB
# - Write logs to CloudWatch
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_combined_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.secure_storage.arn}/*"
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.audit_logs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

############################################
# Lambda Function – Generate Upload Link
############################################
# This Lambda generates a presigned S3 URL for secure uploads
resource "aws_lambda_function" "upload_api" {
  function_name = "SecureUploadAPI"
  filename      = "upload_handler.zip"
  handler       = "upload_handler.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.secure_storage.id
    }
  }
}

############################################
# Lambda Function URL – API Access
############################################
# Exposes the Lambda as an HTTPS endpoint
resource "aws_lambda_function_url" "api_url" {
  function_name      = aws_lambda_function.upload_api.function_name
  authorization_type = "AWS_IAM"

  cors {
    allow_origins = ["*"]
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

############################################
# Lambda Permission – Allow URL Invocation
############################################
# Allows public invocation of the Lambda function URL
resource "aws_lambda_permission" "allow_url_invoke" {
  statement_id           = "AllowExecutionFromURL"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.upload_api.function_name
  principal              = "*"
  function_url_auth_type = "AWS_IAM"
}

############################################
# Outputs
############################################
# Displays the API endpoint after deployment
output "api_endpoint" {
  value = aws_lambda_function_url.api_url.function_url
}
