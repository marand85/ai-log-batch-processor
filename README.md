# AI Log Batch Processor

Serverless batch log analysis tool using Claude Batch API, AWS Lambda, S3, SNS and EventBridge. Automatically collects log files, submits them for AI analysis, and delivers results via email notifications.

## Overview

This project automatically:
- Collects log files uploaded to S3
- Submits them to Claude Batch API (50% cheaper than synchronous API)
- Saves analysis results to S3
- Sends email notifications on batch completion
- Monitors everything via CloudWatch Dashboard

Built with **AWS Lambda**, **S3**, **SNS**, **EventBridge**, **CloudWatch** and deployed via **Terraform** (Infrastructure as Code).


## Architecture
```
Log files uploaded to S3 input/
         |
         v
EventBridge (every 3 min)
         |
         v
Lambda: create_batch
  - Collects all .log files
  - Builds batch requests
  - Submits to Claude Batch API
  - Moves files to input/processed/
  - Sends SNS notification
         |
         v
Claude Batch API (async processing)
         |
         v
EventBridge (every 5 min)
         |
         v
Lambda: check_batch
  - Checks batch status
  - Retrieves results when complete
  - Saves to S3 output/
  - Sends SNS notification
         |
         v
Results in S3 output/ + Email notification
```
## Tech Stack

- **Cloud**: AWS (Lambda, S3, SNS, EventBridge, CloudWatch, IAM)
- **AI**: Claude Sonnet 4 Batch API (Anthropic)
- **Language**: Python 3.12
- **IaC**: Terraform
- **Libraries**: anthropic, boto3

## Project Structure
``` 
ai-log-batch-processor/
├── lambda/
│ └── lambda_function.py # create_batch + check_batch handlers
├── terraform/
│ ├── main.tf # Infrastructure definition
│ ├── variables.tf # Configuration variables
│ ├── outputs.tf # S3 bucket, SNS, dashboard outputs
│ └── terraform.tfvars # Variable values (not in repo)
├── sample-logs/
│ ├── webserver.log # Sample web server logs
│ ├── payments.log # Sample payment service logs
│ └── security.log # Sample security logs
└── README.md
```
## Quick Start

### Prerequisites

- AWS Account with CLI configured
- Terraform >= 1.0
- Anthropic API key
- Email address for SNS notifications

### Deployment

1. Clone repository

``` bash
git clone https://github.com/marand85/ai-log-batch-processor
cd ai-log-batch-processor
```
2. Configure variables
``` bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
# or: code terraform.tfvars
# or: vim terraform.tfvars
```
Edit terraform.tfvars with your values (use your preferred editor):
``` bash
anthropic_api_key  = "sk-ant-your-key-here"
notification_email = "your-email@example.com"
```
3. Deploy infrastructure
``` bash
terraform init
terraform apply
```
4. Confirm SNS subscription
Check your email and click "Confirm subscription" link from AWS.

5. Get S3 bucket name
``` bash
terraform output s3_bucket_name
```
## Usage

### Upload log files to S3

``` bash
aws s3 cp your-file.log s3://YOUR-BUCKET-NAME/input/
```

### Demo Timeline

| Time | Event |
|------|-------|
| 0 min | Upload .log files to S3 input/ |
| ~3 min | Lambda create_batch collects files and submits to Claude |
| ~3 min | Email: "Batch analysis started" |
| ~10-20 min | Claude Batch API processes logs |
| ~25 min | Lambda check_batch retrieves results |
| ~25 min | Email: "Batch log analysis complete" |
| ~25 min | Results saved to S3 output/ |

**Total demo time: ~25-30 minutes** (Actual time: < 10 mins)

Note: Demo uses accelerated schedule (3/5 min intervals).
Production recommended: create_batch every 1 hour, check_batch every 15 minutes.

### Check results


List all generated analyses:
``` bash
aws s3 ls s3://YOUR-BUCKET-NAME/output/
```

Download a specific analysis to your terminal:
``` bash
aws s3 cp s3://YOUR-BUCKET-NAME/output/webserver_analysis.json -
aws s3 cp s3://YOUR-BUCKET-NAME/output/payments_analysis.json -
aws s3 cp s3://YOUR-BUCKET-NAME/output/security_analysis.json -
```

Download ALL results to a local folder at once:
``` bash
aws s3 sync s3://YOUR-BUCKET-NAME/output/ ./analysis-results/
```

View CloudWatch Dashboard:

``` bash
terraform output cloudwatch_dashboard_url
```

## Key Features

- **Automated Workflow** - Zero manual intervention required after file upload
- **Cost-Optimized AI** - Uses Claude Batch API which is 50% cheaper than synchronous API
- **Context Window Management** - Automatically truncates oversized logs to prevent API errors
- **Duplicate Prevention** - Processed files are automatically moved to `input/processed/`
- **Infrastructure as Code** - 100% Terraform deployment (15 AWS resources)

## Monitoring & Observability

- **CloudWatch Dashboard**: Centralized view of Lambda invocations, errors, and execution durations
- **SNS Notifications**: Automated email alerts for batch creation and completion
- **CloudWatch Logs**: Detailed execution logs stored automatically for both Lambda functions

## Security

- **Least Privilege IAM**: Lambda execution roles only have access to specific S3 paths, the designated SNS topic, and CloudWatch.
- **Encrypted Secrets**: The Anthropic API key is stored securely as an encrypted environment variable in AWS Lambda.
- **Private Storage**: S3 bucket blocks public access by default.

## Cost Estimate

| Service | Usage | Estimated Cost |
|---------|-------|----------------|
| AWS Lambda | ~15,000 invocations/month (polling) | ~$0.01 (Free Tier eligible) |
| Amazon S3 | 1 GB storage, ~15k requests | ~$0.05 |
| Claude Batch API | 1000 log files | ~$1.50 (50% cheaper than sync API) |
| **Total** | | **~$1.56/month** |

*Note: Claude API costs depend strictly on log length (token count).*

## Future Enhancements (Enterprise Scale)

While this architecture is perfect for moderate workloads, for enterprise-scale log processing (millions of events), I would implement:
- **Amazon SQS / EventBridge Pipes**: For decoupling S3 uploads from processing.
- **Amazon Kinesis Firehose**: To automatically aggregate small log streams into larger files before hitting S3.
- **AWS Step Functions**: For robust batch orchestration, error handling, and retries.
- **Amazon DynamoDB**: For persistent tracking of batch metadata and historical analysis.

## Author

**Mariusz Andrzejewski**  
AI Platform Engineer  

- GitHub: https://github.com/marand85

## License

MIT License
