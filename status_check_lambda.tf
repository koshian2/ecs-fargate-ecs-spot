# IAMロールの作成
resource "aws_iam_role" "lambda_role" {
  name = "url_health_check_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

# IAMポリシーのアタッチ
resource "aws_iam_role_policy" "lambda_policy" {
  name = "url_health_check_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = ".cache/lambda_function.zip"
}

# Lambda関数の作成
resource "aws_lambda_function" "url_health_check" {
  function_name = "url_health_check"
  role          = aws_iam_role.lambda_role.arn

  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)
  runtime          = "python3.12"
  memory_size      = 256
  timeout          = 30 # 秒単位、必要に応じて調整

  environment {
    variables = {
      FARGATE_URL = "https://fargate.${var.hosted_zone_name}"
      EC2_URL = "https://ec2.${var.hosted_zone_name}"
    }
  }
}

# CloudWatch Event Ruleの作成（1分おきに実行）
resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "url_health_check_every_minute"
  schedule_expression = "rate(1 minute)"
}

# Lambda関数をイベントターゲットとして追加
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.every_minute.name
  target_id = "url_health_check_lambda"
  arn       = aws_lambda_function.url_health_check.arn
}

# Lambda関数にCloudWatch EventsからのInvoke権限を付与
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.url_health_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}
