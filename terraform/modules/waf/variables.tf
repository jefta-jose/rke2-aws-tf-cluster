variable "name" {
  description = "Name prefix (e.g. nonprod-rok)"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to associate the WebACL with"
  type        = string
}

variable "accepted_ips" {
  description = "Source IPs allowed by the AcceptedClusterIPs rule (without /32)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
