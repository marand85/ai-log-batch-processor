import json
import boto3
import anthropic
import os
from textwrap import dedent

s3 = boto3.client('s3')
sns = boto3.client('sns')


def create_batch(event, context):
    """
    Triggered by EventBridge every 3 minutes.
    Collects log files from S3 input/ and submits to Claude Batch API.
    """
    
    bucket = os.environ['S3_BUCKET']
    input_prefix = 'input/'
    
    print(f"Checking for log files in s3://{bucket}/{input_prefix}")
    
    # List all files in input/
    response = s3.list_objects_v2(Bucket=bucket, Prefix=input_prefix)
    
    if 'Contents' not in response:
        print("No files found in input/")
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'No files to process'})
        }
    
    # Filter .log files only
    files = [obj for obj in response['Contents'] 
        if obj['Key'] != input_prefix 
        and obj['Key'].endswith('.log')
        and 'processed/' not in obj['Key']]
    
    if not files:
        print("No .log files found")
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'No .log files to process'})
        }
    
    print(f"Found {len(files)} log files to process")
    
    # Build batch requests (JSONL format handled by SDK)
    batch_requests = []
    
    for file_obj in files:
        key = file_obj['Key']
        filename = key.split('/')[-1]
        
        print(f"Processing: {filename}")
        
        # Read log file
        obj = s3.get_object(Bucket=bucket, Key=key)
        logs = obj['Body'].read().decode('utf-8')
        
        # Truncate if too large for context window
        max_chars = 50000
        if len(logs) > max_chars:
            logs = logs[:max_chars] + "\n\n[LOG TRUNCATED - file exceeds 50,000 characters]"
            print(f"Truncated {filename} from {len(logs)} to {max_chars} chars")
        
        prompt = dedent(f"""
            Analyze these application logs and provide:
            1. Summary of issues found
            2. Severity level (critical/warning/info)
            3. Recommended actions
            4. Statistics (total errors, warnings, critical issues)

            Source file: {filename}

            Logs:
            {logs}
        """).strip()
        
        batch_requests.append({
            "custom_id": filename.replace('.log', ''),
            "params": {
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 2048,
                "messages": [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            }
        })
    
    print(f"Prepared {len(batch_requests)} batch requests")
    
    # Submit to Claude Batch API
    client = anthropic.Anthropic()
    
    try:
        batch = client.messages.batches.create(requests=batch_requests)
        print(f"Batch created: {batch.id}, status: {batch.processing_status}")
    except Exception as e:
        print(f"Error creating batch: {str(e)}")
        raise
    
    # Save batch metadata
    batch_info = {
        'batch_id': batch.id,
        'status': batch.processing_status,
        'file_count': len(files),
        'files': [f['Key'] for f in files],
        'created_at': batch.created_at.isoformat() if hasattr(batch.created_at, 'isoformat') else str(batch.created_at)
    }
    
    s3.put_object(
        Bucket=bucket,
        Key='batch/latest_batch.json',
        Body=json.dumps(batch_info, indent=2),
        ContentType='application/json'
    )
    
    # Move processed files to input/processed/
    for file_obj in files:
        old_key = file_obj['Key']
        new_key = old_key.replace('input/', 'input/processed/')
        
        s3.copy_object(
            Bucket=bucket,
            CopySource={'Bucket': bucket, 'Key': old_key},
            Key=new_key
        )
        s3.delete_object(Bucket=bucket, Key=old_key)
    
    print(f"Moved {len(files)} files to processed/")
    
    # Send SNS notification
    sns_topic_arn = os.environ.get('SNS_TOPIC_ARN')
    if sns_topic_arn:
        message_lines = [
            "Batch analysis started!",
            "",
            f"Batch ID: {batch.id}",
            f"Files processed: {len(files)}",
            "",
            "Files:"
        ]

        for f in files:
            message_lines.append(f"- {f['Key']}")

        message_lines.extend([
            "",
            f"Status: {batch.processing_status}",
            "",
            "Results will be available in ~10-20 minutes."
        ])

        sns.publish(
            TopicArn=sns_topic_arn,
            Subject='Batch Log Analysis Started',
            Message="\n".join(message_lines)
        )
        print("SNS notification sent")  
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'batch_created',
            'batch_id': batch.id,
            'file_count': len(files)
        })
    }


def check_batch(event, context):
    """
    Triggered by EventBridge every 5 minutes.
    Checks batch status and retrieves results if complete.
    """
    
    bucket = os.environ['S3_BUCKET']
    sns_topic_arn = os.environ.get('SNS_TOPIC_ARN')
    
    print("Checking for active batch")
    
    # Read batch metadata
    try:
        response = s3.get_object(Bucket=bucket, Key='batch/latest_batch.json')
        batch_info = json.loads(response['Body'].read().decode('utf-8'))
    except s3.exceptions.NoSuchKey:
        print("No batch metadata found")
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'No active batch'})
        }
    
    batch_id = batch_info['batch_id']
    
    print(f"Found batch: {batch_id}")
    
    # Check batch status
    client = anthropic.Anthropic()
    
    try:
        batch = client.messages.batches.retrieve(batch_id)
    except Exception as e:
        print(f"Error retrieving batch: {str(e)}")
        raise
    
    print(f"Batch {batch_id} status: {batch.processing_status}")
    
    if batch.processing_status != 'ended':
        print(f"Batch still processing (status: {batch.processing_status})")
        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': batch.processing_status,
                'batch_id': batch_id,
                'message': 'Batch still processing'
            })
        }
    
    print("Batch complete - retrieving results")
    
    # Batch complete - retrieve results
    results = []
    
    for result in client.messages.batches.results(batch_id):
        custom_id = result.custom_id
        
        if result.result.type == 'succeeded':
            analysis = result.result.message.content[0].text
            
            output = {
                'source_file': custom_id,
                'status': 'success',
                'analysis': analysis
            }
            
            print(f"Success: {custom_id}")
        else:
            output = {
                'source_file': custom_id,
                'status': 'error',
                'error': str(result.result.error) if hasattr(result.result, 'error') else str(result.result)
            }
            
            print(f"Error: {custom_id} - {output['error']}")
        
        results.append(output)
        
        # Save individual result to S3
        s3.put_object(
            Bucket=bucket,
            Key=f"output/{custom_id}_analysis.json",
            Body=json.dumps(output, indent=2),
            ContentType='application/json'
        )
    
    print(f"Saved {len(results)} analysis results")
    
    # Create summary
    summary = {
        'batch_id': batch_id,
        'total_files': len(results),
        'successful': sum(1 for r in results if r['status'] == 'success'),
        'failed': sum(1 for r in results if r['status'] == 'error'),
        'completed_at': batch.ended_at.isoformat() if hasattr(batch, 'ended_at') and hasattr(batch.ended_at, 'isoformat') else 'unknown'
    }
    
    s3.put_object(
        Bucket=bucket,
        Key='output/batch_summary.json',
        Body=json.dumps(summary, indent=2),
        ContentType='application/json'
    )
    
    # Archive batch metadata
    s3.copy_object(
        Bucket=bucket,
        CopySource={'Bucket': bucket, 'Key': 'batch/latest_batch.json'},
        Key=f"batch/completed/{batch_id}.json"
    )
    s3.delete_object(Bucket=bucket, Key='batch/latest_batch.json')
    
    print("Batch metadata archived")
    
    # Send SNS notification
    if sns_topic_arn:
        message_lines = [
            "Batch log analysis complete!",
            "",
            f"Batch ID: {batch_id}",
            f"Total files: {summary['total_files']}",
            f"Successful: {summary['successful']}",
            f"Failed: {summary['failed']}",
            "",
            f"Results saved to: s3://{bucket}/output/",
            "",
            "Analyzed files:"
        ]
        
        for r in results:
            status_emoji = "✅" if r['status'] == 'success' else "❌"
            message_lines.append(f"{status_emoji} {r['source_file']}")
        
        sns.publish(
            TopicArn=sns_topic_arn,
            Subject='✅ Batch Log Analysis Complete',
            Message="\n".join(message_lines)
        )
        print("SNS notification sent")
    
    return {
        'statusCode': 200,
        'body': json.dumps(summary)
    }
