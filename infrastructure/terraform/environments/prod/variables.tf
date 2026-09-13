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
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR for this environment's VPC. Must not overlap production, so the two can be peered later."
  type        = string
  default     = "10.30.0.0/16"
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
  description = "CloudWatch log retention. Longer than staging: production logs are evidence, not debugging output."
  type        = number
  default     = 90
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

variable "db_instance_class" {
  description = "RDS instance class for production. t4g.small is the floor for a real workload; step up before adding read replicas."
  type        = string
  default     = "db.t4g.small"
}
