resource "aws_dynamodb_table" "demo" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "merchant_id"

  attribute {
    name = "merchant_id"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = false
  }

  deletion_protection_enabled = false

  tags = var.tags
}

resource "aws_dynamodb_table" "control" {
  name         = var.control_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "merchant_id"

  attribute {
    name = "merchant_id"
    type = "S"
  }

  tags = var.tags
}

# recovery_window_in_days = 0 permite recrear el secreto tras un destroy.
resource "aws_secretsmanager_secret" "sqlserver" {
  name                    = var.secret_name
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "sqlserver" {
  secret_id = aws_secretsmanager_secret.sqlserver.id
  secret_string = jsonencode({
    host     = google_compute_address.sqlserver_internal.address
    port     = var.sqlserver_port
    user     = var.sqlserver_app_user
    password = random_password.app.result
    database = var.sqlserver_database
  })
}
