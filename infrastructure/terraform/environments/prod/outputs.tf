output "application_url" {
  description = "Public URL of the application."
  value       = "http://${module.compute.alb_dns_name}"
}

output "alb_dns_name" {
  description = "Load balancer hostname."
  value       = module.compute.alb_dns_name
}

output "image_repository_url" {
  description = "Shared repository this environment pulls from. Created once by infrastructure/terraform/cicd, so a promoted artifact is the same bytes everywhere."
  value       = module.compute.image_repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name, consumed by the CD pipeline."
  value       = module.compute.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS service name, consumed by the CD pipeline."
  value       = module.compute.ecs_service_name
}

output "task_definition_family" {
  description = "Task definition family the CD pipeline registers new revisions against."
  value       = module.compute.task_definition_family
}

output "rds_endpoint" {
  description = "Database endpoint. Reachable only from inside the VPC."
  value       = module.data.endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed credentials. The secret value itself is never an output: printing it would put it in state and in every CI log that runs terraform output."
  value       = module.data.master_user_secret_arn
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "nat_gateway_public_ips" {
  description = "Egress addresses, for third-party allowlists."
  value       = module.network.nat_gateway_public_ips
}

output "application_log_group" {
  description = "CloudWatch log group holding application logs."
  value       = module.compute.log_group_name
}

output "alb_access_logs_bucket" {
  description = "S3 bucket holding ALB access logs."
  value       = module.compute.access_logs_bucket
}

output "cloudwatch_dashboard_url" {
  description = "Link to the platform dashboard."
  value       = module.observability.dashboard_url
}

output "alerts_topic_arn" {
  description = "SNS topic every alarm publishes to."
  value       = module.observability.sns_topic_arn
}
