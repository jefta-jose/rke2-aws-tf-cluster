variable "name" {
  description = "Name prefix for network resources"
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Availability zones for public subnets (>= 2 for an ALB)"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
