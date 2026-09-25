variable "environment" {
  type        = string
  description = "Current working environment"
}

variable "project" {
  type        = string
  description = "Project name"
}

variable "application" {
  type        = string
  description = "Application name"
}

variable "secret_value" {
  type        = string
  description = "Optional JSON secret string to seed. Null = create empty secret only."
  default     = null
}
