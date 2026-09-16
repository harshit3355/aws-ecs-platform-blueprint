variable "aws_region" {
  description = "Region for the provider. IAM itself is global; the region only affects how ARNs are scoped in the policies below."
  type        = string
  default     = "ap-south-1"
}

variable "github_repository" {
  description = "Repository allowed to assume these roles, as owner/name. This is the security boundary: it is matched exactly, never as a prefix."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be exactly owner/name, with no wildcards and no trailing path."
  }
}

variable "resource_name_prefix" {
  description = "Prefix the platform's resources share. Used to scope every ARN these roles can act on."
  type        = string
  default     = "meridian"

  validation {
    condition     = length(var.resource_name_prefix) >= 3
    error_message = "resource_name_prefix must be at least 3 characters; a short prefix scopes nothing."
  }
}

variable "deploy_environments" {
  description = "GitHub Environment names permitted to assume the deploy role. A job only receives an environment subject claim if it declares that environment, which is what routes production through its approval gate."
  type        = list(string)
  default     = ["staging", "production"]
}

variable "max_session_seconds" {
  description = "Maximum session duration for the federated roles."
  type        = number
  default     = 3600
}
