variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a resource name prefix."
  type        = string
  default     = "meridian"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "CIDR for this environment's VPC. Must not overlap production, so the two can be peered later."
  type        = string
  default     = "10.20.0.0/16"
}

variable "image_tag" {
  description = "Image tag for the initial task definition. The CD pipeline supplies real tags thereafter."
  type        = string
  default     = "latest"
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Null means an HTTP-only listener."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Shorter in staging: logs are the second largest line item after compute."
  type        = number
  default     = 14
}

variable "alert_email_addresses" {
  description = "Addresses to subscribe to the alert topic."
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook for alerts. Supply via TF_VAR_slack_webhook_url, never in tfvars."
  type        = string
  default     = null
  sensitive   = true
}

variable "image_repository_url" {
  description = "Shared ECR repository, from `terraform output image_repository_url` in infrastructure/terraform/cicd. One registry serves every environment so a promoted artifact is the same bytes."
  type        = string
}
