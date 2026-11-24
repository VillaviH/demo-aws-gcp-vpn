data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.lambda_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

# Cubre logs y ENIs de VPC sin ec2:* con Resource "*".
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_access" {
  statement {
    sid       = "ReadSourceTable"
    actions   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.demo.arn]
  }

  statement {
    sid       = "WriteControlTable"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.control.arn]
  }

  statement {
    sid       = "ReadSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.sqlserver.arn]
  }
}

resource "aws_iam_role_policy" "lambda_access" {
  name   = "${var.lambda_function_name}-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_access.json
}

# build/lambda-package lo genera scripts/build-lambda.sh (FEAT-003).
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/build/lambda-package"
  output_path = "${path.module}/build/lambda-demo.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_lambda_function" "sync" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SOURCE_TABLE_NAME      = aws_dynamodb_table.demo.name
      SQLSERVER_SECRET_ARN   = aws_secretsmanager_secret.sqlserver.arn
      SQLSERVER_TARGET_TABLE = var.sqlserver_target_table
      CONTROL_TABLE_NAME     = aws_dynamodb_table.control.name
      LOG_LEVEL              = "INFO"
      SCAN_PAGE_SIZE         = tostring(var.scan_page_size)
      TIME_SAFETY_MARGIN_MS  = tostring(var.time_safety_margin_ms)
      APP_ENV                = var.app_env
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy.lambda_access,
    aws_cloudwatch_log_group.lambda,
  ]
}
