variable "environment" { description = "Deployment environment" }
variable "project" { description = "Project name" }
variable "application" { description = "Application or queue purpose identifier" }

variable "visibility_timeout_seconds" {
  description = "Seconds a received message is hidden from other consumers"
  default     = 30
}

variable "message_retention_seconds" {
  description = "Seconds messages are retained before deletion"
  default     = 345600 # 4 days
}

variable "fifo_queue" {
  description = "Create a FIFO queue (name auto-gets the .fifo suffix)"
  default     = false
}

variable "content_based_deduplication" {
  description = "Content-based dedup for FIFO queues"
  default     = false
}

variable "dead_letter_target_arn" {
  description = "DLQ ARN for redrive. Null disables redrive."
  default     = null
}

variable "max_receive_count" {
  description = "Max receives before a message goes to the DLQ"
  default     = 5
}
