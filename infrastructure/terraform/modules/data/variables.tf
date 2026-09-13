variable "name" {
  description = "Name prefix and RDS instance identifier."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database security group belongs to."
  type        = string
}

variable "db_subnet_group_name" {
  description = "DB subnet group from the network module."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "18.6"
}

variable "parameter_group_family" {
  description = "Parameter group family. Must match the engine major version."
  type        = string
  default     = "postgres18"
}

variable "major_engine_version" {
  description = "Major engine version, used for the option group."
  type        = string
  default     = "18"
}

variable "instance_class" {
  description = "RDS instance class. t4g is Graviton and roughly 20 percent cheaper than the equivalent t3."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = startswith(var.instance_class, "db.")
    error_message = "instance_class must start with 'db.'."
  }
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Ceiling for storage autoscaling in GiB. Set equal to allocated_storage to disable autoscaling."
  type        = number
  default     = 100
}

variable "database_name" {
  description = "Name of the initial database."
  type        = string
  default     = "appdb"
}

variable "master_username" {
  description = "Master username. The password is generated and rotated by RDS and never enters Terraform."
  type        = string
  default     = "appadmin"
}

variable "port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "multi_az" {
  description = "Deploy a synchronous standby in a second AZ. Doubles instance cost; required for any real RTO."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention. Any value above 0 also enables point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35. Zero would disable point-in-time recovery entirely."
  }
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Must be false in production."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block terraform destroy and console deletion of the instance."
  type        = bool
  default     = true
}

variable "enable_password_rotation" {
  description = "Have Secrets Manager rotate the RDS master password on a schedule."
  type        = bool
  default     = true
}

variable "password_rotation_days" {
  description = "Rotation interval in days for the master password."
  type        = number
  default     = 30
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring granularity in seconds. 0 disables it; 60 is the usual production value."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention. 7 days is the free tier; anything longer is billed."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "CloudWatch retention for exported PostgreSQL logs."
  type        = number
  default     = 30
}

variable "slow_query_threshold_ms" {
  description = "Log any statement slower than this, in milliseconds."
  type        = number
  default     = 1000
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of in the next maintenance window."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
