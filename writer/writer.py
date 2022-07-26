#!/usr/bin/env python

from datetime import datetime
import boto3
import os
import json
import bleach

def lambda_handler(event, context):
    data = json.loads(event['body'])
    client = boto3.resource('dynamodb')

    data_type = bleach.clean(data['type'])
    data_payload = bleach.clean(data['payload'])

    table = client.Table(os.environ['TABLE_NAME'])

    response = table.put_item(

       Item={

           'timestamp': str(datetime.now()),

           'type': data_type,

           'payload': data_payload

       }

    )
    return {
        'statusCode': response['ResponseMetadata']['HTTPStatusCode'],
        'body': 'Record ' + data_type + ' added'
    }