terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.64"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every resource that supports tagging, so cost allocation and
  # "what is this and who owns it" are answered without per-resource effort.
  default_tags {
    tags = {
      Project     = "meridian-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "meridian-platform"
    }
  }
}
