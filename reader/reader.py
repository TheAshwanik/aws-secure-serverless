#!/usr/bin/env python

from datetime import datetime
import boto3
import os
import json

def lambda_handler(event, context):
    client = boto3.resource('dynamodb')

    table = client.Table(os.environ['TABLE_NAME'])

    response = table.scan()

    return {
        'statusCode': response['ResponseMetadata']['HTTPStatusCode'],
        'body': json.dumps(response['Items'])
    }