output "build_role_arn" {
  description = "Set as the AWS_BUILD_ROLE_ARN repository variable. Assumable only from the main branch."
  value       = aws_iam_role.build.arn
}

output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository variable. Assumable only from a declared GitHub Environment."
  value       = aws_iam_role.deploy.arn
}

output "trusted_build_subjects" {
  description = "Exact OIDC subject claims permitted to assume the build role."
  value       = local.build_subjects
}

output "trusted_deploy_subjects" {
  description = "Exact OIDC subject claims permitted to assume the deploy role."
  value       = local.deploy_subjects
}

output "image_repository_url" {
  description = "Shared container registry. Pass into every environment, and set as the ECR_REPOSITORY repository variable."
  value       = aws_ecr_repository.app.repository_url
}

output "image_repository_name" {
  description = "Repository name, for the ECR_REPOSITORY GitHub variable."
  value       = aws_ecr_repository.app.name
}
