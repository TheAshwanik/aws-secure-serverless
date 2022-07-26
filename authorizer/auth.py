import os
import json

def lambda_handler(event, context):
    print("Client access header: " + event['headers']['jwt'])
    print("Method ARN: " + event['methodArn'])

    tmp = event['methodArn'].split(':')
    apiGatewayArn = tmp[5].split('/')[0]
    region = tmp[3]
    awsAccountId = tmp[4]

    authResponse = {
        'policyDocument':
        {
            'Version': '2012-10-17',
            'Statement': [
                {
                    'Action': 'execute-api:Invoke',
                    'Effect': '',
                    'Resource': [
                        'arn:aws:execute-api:' +
                        region+':'+awsAccountId+':' +
                        apiGatewayArn+'/Prod/*/*'
                    ]
                }
            ]}}

    if(event['headers']['jwt'] == os.environ['JWT']):
        authResponse['policyDocument']['Statement'][0]['Effect'] = 'Allow'
    else:
        authResponse['policyDocument']['Statement'][0]['Effect'] = 'Deny'

    print(authResponse)
    return authResponse