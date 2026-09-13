variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "region" {
  description = "AWS region, used to build VPC endpoint service names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough to split into three /20 tiers."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 4, 11))
    error_message = "vpc_cidr must be a valid CIDR with room for at least 12 /20 subnets (a /16 or larger)."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4: RDS subnet groups and ALBs both require at least two AZs."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ. Cheaper, but a single AZ failure removes egress for every private subnet."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Create interface endpoints for ECR, CloudWatch Logs and Secrets Manager. Only cost-effective above roughly 1.3 TB/month of NAT egress."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send rejected-traffic VPC flow logs to CloudWatch."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch retention for flow logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
