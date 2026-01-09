import json
import urllib.parse
import boto3
import datetime

# --- CONFIGURATION ---
# We initialize these outside the handler for better performance
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('FileAuditLogs')
sns = boto3.client('sns')

# Your specific ARN is already set here:
SNS_TOPIC_ARN = 'arn:aws:sns:eu-north-1:564766582621:FileUploadAlerts'

def lambda_handler(event, context):
    print("Received event:", json.dumps(event)) # Debugging log
    
    try:
        # 1. Validation: Ensure this is actually an S3 event
        if 'Records' not in event:
            print("Event does not contain 'Records'. Skipping.")
            return {
                'statusCode': 400, 
                'body': json.dumps('Not an S3 event')
            }
            
        # 2. Extract File Details
        # We look at the first record in the event list
        record = event['Records'][0]
        bucket_name = record['s3']['bucket']['name']
        # 'unquote_plus' handles spaces or special characters in filenames
        file_key = urllib.parse.unquote_plus(record['s3']['object']['key'], encoding='utf-8')
        file_size = record['s3']['object']['size']
        
        # 3. Prepare Data for DynamoDB
        upload_time = datetime.datetime.now().isoformat()
        
        item = {
            'filename': file_key,
            'upload_time': upload_time,
            'file_size_bytes': str(file_size),
            'file_type': 'image/jpeg',  # Defaulting to jpeg since S3 triggers don't always send MIME type
            'bucket_name': bucket_name,
            'event': 'FILE_UPLOADED'
        }
        
        # 4. Save to DynamoDB
        table.put_item(Item=item)
        print(f"Successfully logged to DynamoDB: {file_key}")
        
        # 5. Send Email Notification via SNS
        email_subject = 'New File Uploaded to Secure Storage'
        email_message = (
            f"ALERT: A new file has been uploaded!\n\n"
            f"File Name: {file_key}\n"
            f"Size: {file_size} bytes\n"
            f"Bucket: {bucket_name}\n"
            f"Time: {upload_time}"
        )
        
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=email_subject,
            Message=email_message
        )
        print(f"Email sent to SNS Topic: {SNS_TOPIC_ARN}")
        
        return {
            'statusCode': 200,
            'body': json.dumps('Audit log saved and email sent!')
        }
        
    except Exception as e:
        # If anything goes wrong, print the error to CloudWatch logs
        print(f"CRITICAL ERROR: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error processing file: {str(e)}")
        }
