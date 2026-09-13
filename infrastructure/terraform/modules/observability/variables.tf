variable "name" {
  description = "Name prefix for alarms, topic and dashboard."
  type        = string
}

variable "metric_namespace" {
  description = "CloudWatch namespace for metrics derived from logs."
  type        = string
  default     = "Meridian/Application"
}

# ---- targets to observe ----

variable "alb_arn_suffix" {
  description = "ALB ARN suffix, from the compute module."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix, from the compute module."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name."
  type        = string
}

variable "rds_instance_identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "app_log_group_name" {
  description = "CloudWatch log group receiving application logs."
  type        = string
}

# ---- notification ----

variable "alert_email_addresses" {
  description = "Addresses subscribed to the alert topic. Each must confirm the subscription by email before it receives anything."
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook for alerts. This is a credential: supply it through TF_VAR_slack_webhook_url from a secret store, never in a tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

# ---- thresholds ----
# Deliberately variables rather than constants: the right threshold for staging
# is not the right threshold for production, and a threshold nobody can tune is
# a threshold that eventually gets muted.

variable "error_log_threshold" {
  description = "ERROR log lines in a 5 minute window before alerting."
  type        = number
  default     = 5
}

variable "alb_5xx_threshold" {
  description = "5xx responses in a 5 minute window before alerting."
  type        = number
  default     = 5
}

variable "latency_p99_threshold_seconds" {
  description = "p99 target response time objective, in seconds."
  type        = number
  default     = 1.5
}

variable "ecs_cpu_threshold" {
  description = "Average service CPU percentage before alerting."
  type        = number
  default     = 85
}

variable "ecs_memory_threshold" {
  description = "Average service memory percentage before alerting."
  type        = number
  default     = 85
}

variable "min_running_tasks" {
  description = "Running task count below which the service is considered down."
  type        = number
  default     = 1
}

variable "rds_cpu_threshold" {
  description = "Average database CPU percentage before alerting."
  type        = number
  default     = 80
}

variable "rds_free_storage_threshold_bytes" {
  description = "Free storage floor in bytes. Default is 4 GiB."
  type        = number
  default     = 4294967296
}

variable "rds_freeable_memory_threshold_bytes" {
  description = "Freeable memory floor in bytes. Default is 256 MiB."
  type        = number
  default     = 268435456
}

variable "rds_connection_threshold" {
  description = "Database connection count before alerting. Should be well below the instance class limit."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
