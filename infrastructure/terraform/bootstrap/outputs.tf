output "state_bucket_name" {
  description = "Bucket to reference from each environment's backend block."
  value       = aws_s3_bucket.state.id
}

output "backend_config_snippet" {
  description = "Paste-ready backend block for a new environment."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "<env>/terraform.tfstate"
        region       = "${var.aws_region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
