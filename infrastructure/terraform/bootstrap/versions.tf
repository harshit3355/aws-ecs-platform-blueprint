terraform {
  # 1.11 is the floor: S3 native state locking (use_lockfile) landed there and
  # removes the DynamoDB lock table this project would otherwise need.
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

  default_tags {
    tags = {
      Project   = "meridian-platform"
      ManagedBy = "terraform"
      Component = "tfstate-backend"
    }
  }
}
