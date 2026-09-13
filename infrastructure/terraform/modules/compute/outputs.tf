output "alb_dns_name" {
  description = "Public hostname of the load balancer. This is the application URL."
  value       = module.alb.dns_name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the load balancer, used as a CloudWatch dimension."
  value       = module.alb.arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group, used as a CloudWatch dimension."
  value       = module.alb.target_groups["app"].arn_suffix
}

output "alb_security_group_id" {
  description = "Security group attached to the load balancer."
  value       = module.alb.security_group_id
}

output "access_logs_bucket" {
  description = "S3 bucket holding ALB access logs."
  value       = aws_s3_bucket.alb_logs.id
}

output "ecr_repository_url" {
  description = "Repository the CD pipeline pushes to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN, for scoping the CI deploy role."
  value       = aws_ecr_repository.app.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name, consumed by the CD pipeline."
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "ecs_service_name" {
  description = "ECS service name, consumed by the CD pipeline."
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Task definition family the pipeline registers new revisions against."
  value       = aws_ecs_task_definition.app.family
}

output "task_security_group_id" {
  description = "Security group attached to the ECS tasks. Pass this to the data module so RDS admits the application."
  value       = aws_security_group.tasks.id
}

output "task_execution_role_arn" {
  description = "Task execution role ARN."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Task role ARN."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving application logs."
  value       = aws_cloudwatch_log_group.app.name
}
