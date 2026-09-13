# Data layer: PostgreSQL on RDS.
#
# Secret management note -- this is the important part of this module.
# manage_master_user_password = true hands password generation, storage and
# rotation to RDS itself. The password is created inside AWS, stored in Secrets
# Manager, and NEVER passes through Terraform. It therefore never appears in the
# plan output, never appears in state, and is never visible to whoever runs the
# apply. The alternative -- random_password plus aws_secretsmanager_secret --
# writes the generated value into state in plaintext, which makes the state
# bucket itself a credential store.

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-rds-"
  description = "PostgreSQL access for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds" })

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress is granted by the compute module, which creates a rule from the ECS
# task security group to this one. The rule lives there rather than here so
# the dependency runs one way (compute -> data) instead of forming a cycle:
# the application needs the database endpoint, so the application layer is
# also the layer that declares it needs access.

# No egress rules at all. A database has no legitimate reason to open outbound
# connections, and the database subnets have no route to the internet anyway --
# this is the belt to that route table's braces.

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.1"

  identifier = var.name

  engine               = "postgres"
  engine_version       = var.engine_version
  family               = var.parameter_group_family
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  # gp3 gives a baseline 3000 IOPS at any size, so a small volume is not also a
  # slow volume the way it was on gp2.
  storage_type      = "gp3"
  allocated_storage = var.allocated_storage
  # Storage autoscaling: the cheapest possible protection against the 3am page
  # for a full disk.
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username
  port     = var.port

  manage_master_user_password                            = true
  manage_master_user_password_rotation                   = var.enable_password_rotation
  master_user_password_rotation_automatically_after_days = var.password_rotation_days

  multi_az = var.multi_az

  # The database subnet group comes from the network module, which is what keeps
  # RDS in the tier with no internet route.
  create_db_subnet_group = false
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # ---- backup and recovery ----
  backup_retention_period = var.backup_retention_days
  # Backup and maintenance windows are pinned rather than left to AWS so they
  # land off-peak for the Indian business day (UTC+5:30) instead of moving.
  backup_window      = "18:00-19:00"
  maintenance_window = "Sun:19:30-Sun:20:30"

  copy_tags_to_snapshot    = true
  delete_automated_backups = false
  skip_final_snapshot      = var.skip_final_snapshot
  deletion_protection      = var.deletion_protection

  # ---- observability ----
  enabled_cloudwatch_logs_exports        = ["postgresql", "upgrade"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  performance_insights_enabled          = true
  performance_insights_retention_period = var.performance_insights_retention_days

  create_monitoring_role = var.monitoring_interval > 0
  monitoring_interval    = var.monitoring_interval
  monitoring_role_name   = "${var.name}-rds-monitoring"

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  create_db_parameter_group = true
  parameter_group_name      = "${var.name}-pg"
  parameters = [
    {
      # Reject any connection that is not TLS. Without this, "the database is
      # in a private subnet" is the only thing protecting the wire.
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "pending-reboot"
    },
    {
      # Log statements slower than this. The single highest-value Postgres
      # setting for diagnosing latency that the RED dashboard reports but
      # cannot explain.
      name         = "log_min_duration_statement"
      value        = tostring(var.slow_query_threshold_ms)
      apply_method = "immediate"
    },
    {
      name         = "log_autovacuum_min_duration"
      value        = "10000"
      apply_method = "immediate"
    },
    {
      name         = "log_lock_waits"
      value        = "1"
      apply_method = "immediate"
    },
  ]

  tags = var.tags
}
