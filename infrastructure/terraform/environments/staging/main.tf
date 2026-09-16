# Staging environment.
#
# Deliberately identical in shape to production and different only in size and
# risk posture. Anything that differs structurally between the two is something
# staging cannot test.

locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Environment = var.environment
    CostCentre  = "engineering"
  }
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.aws_region
  vpc_cidr = var.vpc_cidr
  az_count = 2

  # Staging accepts a single NAT gateway. It saves roughly 32 USD/month per
  # additional AZ and the only thing it costs is egress redundancy in an
  # environment that is allowed to be down.
  single_nat_gateway = true

  # Interface endpoints are ~60 USD/month for four services across two AZs and
  # only pay for themselves above roughly 1.3 TB/month of NAT egress. Staging
  # does not come close.
  enable_vpc_endpoints = false

  enable_flow_logs   = true
  log_retention_days = var.log_retention_days

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name                 = local.name
  vpc_id               = module.network.vpc_id
  db_subnet_group_name = module.network.database_subnet_group_name

  # db.t4g.micro is not offered for PostgreSQL in every region -- ap-south-1
  # included -- so t4g.small is the smallest Graviton class that is actually
  # orderable here. The data source in the data module verifies this at plan
  # time rather than ten minutes into an apply.
  instance_class        = "db.t4g.small"
  allocated_storage     = 20
  max_allocated_storage = 50

  # Single AZ: staging does not need a synchronous standby, and Multi-AZ doubles
  # the instance cost.
  multi_az = false

  backup_retention_days = 7
  # Staging is expected to be rebuilt. Production is not -- see environments/prod.
  skip_final_snapshot = true
  deletion_protection = false

  enable_password_rotation = true
  password_rotation_days   = 30

  # Enhanced Monitoring is billed per instance per month. Staging uses the free
  # 60-second CloudWatch metrics instead.
  monitoring_interval = 0

  log_retention_days = var.log_retention_days
  apply_immediately  = true

  tags = local.tags
}

module "compute" {
  source = "../../modules/compute"

  name        = local.name
  environment = var.environment

  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  # Terraform seeds the first task definition; every deploy after that comes
  # from the CD pipeline, which is why the service ignores task_definition.
  image_repository_url = var.image_repository_url
  image_tag            = var.image_tag
  container_port       = 8000

  task_cpu    = 256
  task_memory = 512

  desired_count = 1
  min_capacity  = 1
  max_capacity  = 3

  # Staging runs entirely on Fargate Spot: roughly 70 percent cheaper, and an
  # interruption in staging is a non-event.
  fargate_base_count  = 0
  fargate_weight      = 0
  fargate_spot_weight = 1

  db_host              = module.data.address
  db_port              = module.data.port
  db_name              = module.data.database_name
  db_secret_arn        = module.data.master_user_secret_arn
  db_security_group_id = module.data.security_group_id

  # No ACM certificate: this environment has no domain, so the listener is
  # plain HTTP. The README is explicit that this is a stated limitation of the
  # environment, not an oversight. See docs/adr/0007-tls-termination.md.
  certificate_arn = var.certificate_arn

  enable_deletion_protection = false
  log_bucket_force_destroy   = true
  log_retention_days         = var.log_retention_days
  access_log_retention_days  = 30

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

  # Staging thresholds are looser: it is a place to break things, and an alert
  # that fires constantly in staging trains everyone to ignore the production
  # one that shares its name.
  error_log_threshold           = 20
  alb_5xx_threshold             = 20
  latency_p99_threshold_seconds = 3
  min_running_tasks             = 1
  rds_connection_threshold      = 40

  tags = local.tags
}
