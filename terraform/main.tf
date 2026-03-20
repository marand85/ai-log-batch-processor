terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Package Lambda code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}

# S3 Bucket for logs
resource "aws_s3_bucket" "logs" {
  bucket = "${var.project_name}-logs-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# SNS Topic for notifications
resource "aws_sns_topic" "notifications" {
  name = "${var.project_name}-notifications"
}

# SNS Email subscription
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy - Lambda access to S3, SNS, CloudWatch
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:CopyObject"
        ]
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.notifications.arn
      },
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

# Lambda - Create Batch
resource "aws_lambda_function" "create_batch" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-create-batch"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.create_batch"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 120

  environment {
    variables = {
      ANTHROPIC_API_KEY = var.anthropic_api_key
      S3_BUCKET         = aws_s3_bucket.logs.id
      SNS_TOPIC_ARN     = aws_sns_topic.notifications.arn
    }
  }
}

# Lambda - Check Batch
resource "aws_lambda_function" "check_batch" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-check-batch"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.check_batch"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 120

  environment {
    variables = {
      ANTHROPIC_API_KEY = var.anthropic_api_key
      S3_BUCKET         = aws_s3_bucket.logs.id
      SNS_TOPIC_ARN     = aws_sns_topic.notifications.arn
    }
  }
}

# EventBridge - Create Batch every 3 minutes
resource "aws_cloudwatch_event_rule" "create_batch_schedule" {
  name                = "${var.project_name}-create-batch-schedule"
  description         = "Trigger create_batch Lambda every 3 minutes"
  schedule_expression = "rate(3 minutes)"
}

resource "aws_cloudwatch_event_target" "create_batch_target" {
  rule      = aws_cloudwatch_event_rule.create_batch_schedule.name
  target_id = "CreateBatchLambda"
  arn       = aws_lambda_function.create_batch.arn
}

resource "aws_lambda_permission" "allow_eventbridge_create" {
  statement_id  = "AllowEventBridgeCreate"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_batch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.create_batch_schedule.arn
}

# EventBridge - Check Batch every 5 minutes
resource "aws_cloudwatch_event_rule" "check_batch_schedule" {
  name                = "${var.project_name}-check-batch-schedule"
  description         = "Trigger check_batch Lambda every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "check_batch_target" {
  rule      = aws_cloudwatch_event_rule.check_batch_schedule.name
  target_id = "CheckBatchLambda"
  arn       = aws_lambda_function.check_batch.arn
}

resource "aws_lambda_permission" "allow_eventbridge_check" {
  statement_id  = "AllowEventBridgeCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_batch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.check_batch_schedule.arn
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Create Batch - Invocations & Errors"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.create_batch.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.create_batch.function_name]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Check Batch - Invocations & Errors"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.check_batch.function_name],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.check_batch.function_name]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Create Batch - Duration"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.create_batch.function_name]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Check Batch - Duration"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.check_batch.function_name]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
        }
      }
    ]
  })
}