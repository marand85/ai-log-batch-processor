output "s3_bucket_name" {
  description = "S3 bucket name for log files"
  value       = aws_s3_bucket.logs.id
}

output "sns_topic_arn" {
  description = "SNS topic ARN for notifications"
  value       = aws_sns_topic.notifications.arn
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "demo_instructions" {
  description = "Demo instructions"
  value       = <<-EOT
    === DEMO INSTRUCTIONS ===
    
    1. Upload log files to S3:
       aws s3 cp your-file.log s3://${aws_s3_bucket.logs.id}/input/
    
    2. Wait for batch processing (~25-30 minutes):
       - Lambda create_batch runs every 3 minutes
       - Lambda check_batch runs every 5 minutes
       - Claude Batch API takes ~10-20 minutes
    
    3. Check results:
       aws s3 ls s3://${aws_s3_bucket.logs.id}/output/
    
    4. View CloudWatch dashboard:
       ${"https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"}
    
    5. Check your email for SNS notifications
  EOT
}