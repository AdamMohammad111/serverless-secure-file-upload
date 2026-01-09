import json
import boto3
from decimal import Decimal

# Helper to fix "Decimal" error when reading numbers from DynamoDB
class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super(DecimalEncoder, self).default(obj)

# 1. Connect to DynamoDB
dynamodb = boto3.resource('dynamodb')
TABLE_NAME = 'FileAuditLogs' 
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    try:
        # 2. Get all data from the table
        response = table.scan()
        items = response.get('Items', [])

        # 3. Return the data to your website
        return {
            'statusCode': 200,
            'headers': {
                "Access-Control-Allow-Origin": "*", # Allows your browser to read this
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Allow-Methods": "OPTIONS,GET"
            },
            'body': json.dumps(items, cls=DecimalEncoder)
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error: {str(e)}")
        }
