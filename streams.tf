# Todo el bloque es condicional: con enable_streams_sync = false no se crea nada.
resource "aws_sqs_queue" "streams_dlq" {
  count = var.enable_streams_sync ? 1 : 0

  name                      = "demo-dynamodb-sqlserver-streams-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "streams" {
  count = var.enable_streams_sync ? 1 : 0

  statement {
    sid       = "ReadStream"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator"]
    resources = [aws_dynamodb_table.demo.stream_arn]
  }

  # ListStreams no admite restriccion por recurso.
  statement {
    sid       = "ListStreams"
    actions   = ["dynamodb:ListStreams"]
    resources = ["*"]
  }

  statement {
    sid       = "SendToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.streams_dlq[0].arn]
  }
}

resource "aws_iam_role_policy" "streams" {
  count = var.enable_streams_sync ? 1 : 0

  name   = "${var.lambda_function_name}-streams"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.streams[0].json
}

resource "aws_lambda_event_source_mapping" "streams" {
  count = var.enable_streams_sync ? 1 : 0

  event_source_arn        = aws_dynamodb_table.demo.stream_arn
  function_name           = aws_lambda_function.sync.arn
  starting_position       = var.streams_starting_position
  batch_size              = var.streams_batch_size
  maximum_retry_attempts  = var.streams_maximum_retry_attempts
  function_response_types = ["ReportBatchItemFailures"]

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.streams_dlq[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.streams]
}
