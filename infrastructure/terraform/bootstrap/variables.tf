variable "aws_region" {
  description = "Region the state bucket lives in. Must match the region set in each environment's backend block."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "Must be a valid S3 bucket name: lowercase letters, digits, hyphens and dots, 3-63 characters."
  }
}
