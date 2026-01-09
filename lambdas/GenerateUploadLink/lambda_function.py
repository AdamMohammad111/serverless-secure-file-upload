import json
import boto3
import os
from botocore.exceptions import ClientError

# Connect to S3
s3_client = boto3.client("s3")

def lambda_handler(event, context):
    # 1) Bucket name from environment variables
    bucket_name = os.environ.get("BUCKET_NAME")
    if not bucket_name:
        return {
            "statusCode": 500,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
            },
            "body": json.dumps("Error: BUCKET_NAME environment variable is not set"),
        }

    # 2) Get filename from query string
    params = event.get("queryStringParameters") or {}
    file_name = params.get("filename")

    if not file_name:
        return {
            "statusCode": 400,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
            },
            "body": json.dumps("Error: No filename provided"),
        }

    # Prevent weird paths like "../../" or nested folders if you don't want them
    if ".." in file_name or file_name.startswith("/") or "\\" in file_name:
        return {
            "statusCode": 400,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
            },
            "body": json.dumps("Error: Invalid filename"),
        }

    # 3) Generate presigned PUT URL 
    try:
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": bucket_name,
                "Key": file_name,
            },
            ExpiresIn=300,
        )

        # 4) Return the URL
        return {
            "statusCode": 200,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
                "Content-Type": "application/json",
            },
            "body": json.dumps({
                "upload_url": presigned_url,
                "filename": file_name
            }),
        }

    except ClientError as e:
        return {
            "statusCode": 500,
            "headers": {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
                "Content-Type": "application/json",
            },
            "body": json.dumps(f"Error: {str(e)}"),
        }
