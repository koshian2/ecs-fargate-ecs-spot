import json
import urllib.request
import urllib.error
import boto3
import os

# CloudWatchのクライアントを初期化
cloudwatch = boto3.client('cloudwatch')

# 環境変数からURLを取得
URLS = [
    {
        'name': 'Fargate',
        'url': os.environ["FARGATE_URL"]
    },
    {
        'name': 'EC2',
        'url': os.environ["EC2_URL"]
    }
]

# カスタムメトリクスのネームスペース
NAMESPACE = 'URLHealthCheck'

def lambda_handler(event, context):
    metric_data = []
    
    for site in URLS:
        name = site['name']
        url = site['url']
        status = 0  # デフォルトは失敗とする

        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                if response.status == 200:
                    status = 1
                else:
                    print(f"{name} - Unexpected status code: {response.status}")
        except urllib.error.HTTPError as e:
            print(f"{name} - HTTPError: {e.code}")
        except urllib.error.URLError as e:
            print(f"{name} - URLError: {e.reason}")
        except Exception as e:
            print(f"{name} - Unexpected error: {str(e)}")
        
        # メトリクスデータを準備
        metric = {
            'MetricName': f'{name}StatusCode',
            'Dimensions': [
                {
                    'Name': 'URL',
                    'Value': url
                },
            ],
            'Unit': 'Count',
            'Value': status
        }
        metric_data.append(metric)
    
    if metric_data:
        try:
            cloudwatch.put_metric_data(
                Namespace=NAMESPACE,
                MetricData=metric_data
            )
            print(f"Successfully sent metrics: {metric_data}")
        except Exception as e:
            print(f"Failed to send metrics to CloudWatch: {str(e)}")
    
    return {
        'statusCode': 200,
        'body': json.dumps('Metrics published successfully.')
    }
