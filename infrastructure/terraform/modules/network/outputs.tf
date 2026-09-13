output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets, for the internet-facing load balancer."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnets, for ECS tasks."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "Database subnets, for RDS."
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "RDS DB subnet group created alongside the database subnets."
  value       = module.vpc.database_subnet_group_name
}

output "availability_zones" {
  description = "Availability zones the VPC spans."
  value       = local.azs
}

output "nat_gateway_public_ips" {
  description = "Egress addresses of the NAT gateways, for allowlisting with third parties."
  value       = module.vpc.nat_public_ips
}
