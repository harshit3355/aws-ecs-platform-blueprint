variable "name" {
  description = "Name prefix for cluster, service, repository and load balancer."
  type        = string
}

variable "environment" {
  description = "Environment name, surfaced to the application as APP_ENV."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for the ECS tasks."
  type        = list(string)
}

# ---- container ----

variable "image_tag" {
  description = "Image tag Terraform seeds the first task definition with. Subsequent deploys are driven by the CD pipeline, which is why the service ignores task_definition changes."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "Path the load balancer polls. Must not touch the database."
  type        = string
  default     = "/health"
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 = 0.25 vCPU."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "task_cpu must be one of the Fargate-supported values: 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = "Fargate memory in MiB. Valid values depend on task_cpu."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "ARM64 or X86_64. ARM64 (Graviton) is cheaper and is what CI builds."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "log_level" {
  description = "Application log level."
  type        = string
  default     = "INFO"
}

variable "extra_environment" {
  description = "Additional non-secret environment variables for the container."
  type        = map(string)
  default     = {}
}

# ---- database wiring ----

variable "db_host" {
  description = "RDS hostname."
  type        = string
}

variable "db_port" {
  description = "RDS port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Database name."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret. Individual JSON keys are referenced by the task definition; the value is never read by Terraform."
  type        = string
}

# ---- scaling ----

variable "desired_count" {
  description = "Initial task count. Ignored after creation; the autoscaler owns it from then on."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Autoscaling floor."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Autoscaling ceiling. Also the blast radius limit for a runaway scale-out bill."
  type        = number
  default     = 4
}

variable "cpu_target_utilization" {
  description = "Target average CPU percentage for the scaling policy."
  type        = number
  default     = 65
}

variable "requests_per_target_target" {
  description = "Target ALB requests per task. Set to 0 to disable request-based scaling."
  type        = number
  default     = 0
}

variable "fargate_base_count" {
  description = "Guaranteed on-demand Fargate tasks before Spot is used."
  type        = number
  default     = 1
}

variable "fargate_weight" {
  description = "Relative weight of on-demand Fargate in the capacity provider strategy."
  type        = number
  default     = 1
}

variable "fargate_spot_weight" {
  description = "Relative weight of Fargate Spot. Spot is roughly 70 percent cheaper but interruptible."
  type        = number
  default     = 0
}

# ---- load balancer ----

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. When null, only an HTTP listener is created and the README says so."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "ALB SSL policy. TLS 1.2 minimum."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_deletion_protection" {
  description = "Prevent accidental deletion of the load balancer."
  type        = bool
  default     = false
}

# ---- operations ----

variable "container_insights_mode" {
  description = "Container Insights setting: enabled, enhanced or disabled. Enhanced adds per-container detail and costs more."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced", "disabled"], var.container_insights_mode)
    error_message = "container_insights_mode must be enabled, enhanced or disabled."
  }
}

variable "enable_execute_command" {
  description = "Allow ECS Exec shells into running tasks. Sessions are logged to CloudWatch."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch retention for application and exec logs."
  type        = number
  default     = 30
}

variable "access_log_retention_days" {
  description = "Days to keep ALB access logs in S3 before expiry."
  type        = number
  default     = 90
}

variable "log_bucket_force_destroy" {
  description = "Allow terraform destroy to delete a non-empty access log bucket. Should be false in production."
  type        = bool
  default     = false
}

variable "ecr_keep_last_images" {
  description = "Number of tagged release images to retain in ECR."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "db_security_group_id" {
  description = "Security group attached to RDS. The compute module adds the ingress rule allowing its tasks in."
  type        = string
}
