output "endpoint" {
  description = "Connection endpoint, host:port."
  value       = module.db.db_instance_endpoint
}

output "address" {
  description = "Hostname of the instance, without the port."
  value       = module.db.db_instance_address
}

output "port" {
  description = "Port the instance listens on."
  value       = module.db.db_instance_port
}

output "database_name" {
  description = "Name of the initial database."
  value       = var.database_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the RDS-managed master credentials. The ECS task definition references JSON keys inside this ARN; the value itself is never read by Terraform."
  value       = module.db.db_instance_master_user_secret_arn
}

output "security_group_id" {
  description = "Security group attached to the database."
  value       = aws_security_group.db.id
}

output "instance_identifier" {
  description = "RDS instance identifier, for CloudWatch dimensions."
  value       = module.db.db_instance_identifier
}

output "cloudwatch_log_groups" {
  description = "Log groups receiving the exported PostgreSQL logs."
  value       = module.db.db_instance_cloudwatch_log_groups
}
