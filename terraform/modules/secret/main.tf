# Mirrors rok-scaleout secret module: "<env>-<project>-<app>-secret".
resource "aws_secretsmanager_secret" "secret" {
  name                           = "${var.environment}-${var.project}-${var.application}-secret"
  force_overwrite_replica_secret = false
  recovery_window_in_days        = 30

  tags = {
    Project     = var.project
    Environment = var.environment
    Name        = "${var.environment}-${var.project}-${var.application}-secret"
    Terraform   = "true"
  }
}

# Lab addition (real repo seeds values out-of-band): give ESO something to sync.
resource "aws_secretsmanager_secret_version" "secret" {
  count         = var.secret_value == null ? 0 : 1
  secret_id     = aws_secretsmanager_secret.secret.id
  secret_string = var.secret_value
}
