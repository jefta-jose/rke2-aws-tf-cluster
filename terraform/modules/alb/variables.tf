variable "name" {
  description = "Name prefix (e.g. development-rok)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Public subnet IDs (>= 2 AZs)"
  type        = list(string)
}

variable "traefik_nodeport" {
  description = "Traefik NodePort the ALB forwards to"
  type        = number
  default     = 30080
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "tags" {
  type    = map(string)
  default = {}
}
