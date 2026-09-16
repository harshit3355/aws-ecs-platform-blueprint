# Production environment.
#
# Structurally identical to staging -- same four modules, same wiring. Every
# difference below is a deliberate trade of money for durability, and each one
# is commented with what it buys. A production environment that differs in
# shape from staging is a production environment staging cannot test.

locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Environment = var.environment
    CostCentre  = "engineering"
    Criticality = "high"
  }
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.aws_region
  vpc_cidr = var.vpc_cidr
  az_count = 2

  # One NAT gateway per AZ. Roughly 32 USD/month more than the shared gateway,
  # and it buys the property that losing an AZ does not remove egress for the
  # surviving AZ's tasks.
  single_nat_gateway = false

  # At production traffic the interface endpoints pay for themselves against NAT
  # data processing charges, and they also keep image pulls, log delivery and
  # secret reads off the public internet entirely.
  enable_vpc_endpoints = true

  enable_flow_logs   = true
  log_retention_days = var.log_retention_days

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name                 = local.name
  vpc_id               = module.network.vpc_id
  db_subnet_group_name = module.network.database_subnet_group_name

  instance_class        = var.db_instance_class
  allocated_storage     = 50
  max_allocated_storage = 500

  # Multi-AZ doubles the instance cost and is the only way to get an RTO
  # measured in minutes rather than hours.
  multi_az = true

  backup_retention_days = 30
  # Both false on purpose. Between them these are what stops a mistyped
  # `terraform destroy` from being unrecoverable.
  skip_final_snapshot = false
  deletion_protection = true

  enable_password_rotation = true
  password_rotation_days   = 30

  # 60-second Enhanced Monitoring: the only way to see OS-level metrics from
  # inside the managed instance when a query storm hits.
  monitoring_interval                 = 60
  performance_insights_retention_days = 7

  log_retention_days = var.log_retention_days
  # Never apply a modification outside the maintenance window in production.
  apply_immediately = false

  tags = local.tags
}

module "compute" {
  source = "../../modules/compute"

  name        = local.name
  environment = var.environment

  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  image_repository_url = var.image_repository_url
  image_tag            = var.image_tag
  container_port       = 8000

  task_cpu    = 512
  task_memory = 1024

  desired_count = 2
  # Floor of 2 so a single task failure or an AZ event is never a full outage.
  min_capacity = 2
  max_capacity = 10

  # A guaranteed on-demand base of 2 tasks, bursting onto Spot above that. Spot
  # capacity can be reclaimed with two minutes of notice, so it carries the
  # peak, never the baseline.
  fargate_base_count  = 2
  fargate_weight      = 1
  fargate_spot_weight = 2

  cpu_target_utilization = 60
  # Request-count scaling reacts before CPU does for an I/O-bound service.
  requests_per_target_target = 500

  db_host              = module.data.address
  db_port              = module.data.port
  db_name              = module.data.database_name
  db_secret_arn        = module.data.master_user_secret_arn
  db_security_group_id = module.data.security_group_id

  # Supply a real certificate here and port 80 becomes a 301 to 443
  # automatically. See README, "Security considerations".
  certificate_arn = var.certificate_arn

  enable_deletion_protection = true
  log_bucket_force_destroy   = false
  log_retention_days         = var.log_retention_days
  access_log_retention_days  = 365

  tags = local.tags
}

module "observability" {
  source = "../../modules/observability"

  name = local.name

  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  ecs_cluster_name        = module.compute.ecs_cluster_name
  ecs_service_name        = module.compute.ecs_service_name
  rds_instance_identifier = module.data.instance_identifier
  app_log_group_name      = module.compute.log_group_name

  alert_email_addresses = var.alert_email_addresses
  slack_webhook_url     = var.slack_webhook_url

  error_log_threshold           = 5
  alb_5xx_threshold             = 5
  latency_p99_threshold_seconds = 1.5
  min_running_tasks             = 2
  rds_connection_threshold      = 80

  tags = local.tags
}
