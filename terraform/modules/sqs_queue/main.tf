# Mirrors rok-scaleout modules/sqs_queue verbatim (name, SSE, redrive, producer/consumer policies).
locals {
  queue_name = var.fifo_queue ? "${var.environment}-${var.project}-${var.application}.fifo" : "${var.environment}-${var.project}-${var.application}"
}

resource "aws_sqs_queue" "this" {
  name                        = local.queue_name
  visibility_timeout_seconds  = var.visibility_timeout_seconds
  message_retention_seconds   = var.message_retention_seconds
  sqs_managed_sse_enabled     = true
  fifo_queue                  = var.fifo_queue
  content_based_deduplication = var.fifo_queue ? var.content_based_deduplication : null

  redrive_policy = var.dead_letter_target_arn != null ? jsonencode({
    deadLetterTargetArn = var.dead_letter_target_arn
    maxReceiveCount     = var.max_receive_count
  }) : null

  tags = {
    Name        = local.queue_name
    Terraform   = "true"
    Environment = var.environment
    Application = var.application
  }
}

resource "aws_iam_policy" "producer" {
  name        = "${var.environment}-${var.project}-${var.application}-sqs-producer"
  description = "Allows sending messages to the ${var.environment}-${var.project}-${var.application} SQS queue"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.this.arn
    }]
  })
}

resource "aws_iam_policy" "consumer" {
  name        = "${var.environment}-${var.project}-${var.application}-sqs-consumer"
  description = "Allows receiving and deleting messages from the ${var.environment}-${var.project}-${var.application} SQS queue"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.this.arn
    }]
  })
}
