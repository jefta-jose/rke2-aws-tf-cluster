output "queue_url" { value = aws_sqs_queue.this.url }
output "queue_arn" { value = aws_sqs_queue.this.arn }
output "queue_name" { value = aws_sqs_queue.this.name }
output "producer_policy_arn" { value = aws_iam_policy.producer.arn }
output "consumer_policy_arn" { value = aws_iam_policy.consumer.arn }
