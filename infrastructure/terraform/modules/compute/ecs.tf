# ---------------------------------------------------------------------------
# Log groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}/app"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "exec" {
  count = var.enable_execute_command ? 1 : 0

  # ECS Exec sessions are recorded here. An audited shell is the difference
  # between "we can debug production" and "anyone can debug production".
  name              = "/ecs/${var.name}/exec"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    # Container Insights is where the task-level CPU, memory and ephemeral disk
    # metrics reported on the platform dashboard actually come from.
    name  = "containerInsights"
    value = var.container_insights_mode
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      execute_command_configuration {
        logging = "OVERRIDE"

        log_configuration {
          cloud_watch_log_group_name = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Spot is roughly 70 percent cheaper but can be reclaimed with two minutes of
  # notice. Staging runs entirely on Spot; production keeps a guaranteed
  # on-demand base and only bursts onto Spot.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.fargate_base_count
    weight            = var.fargate_weight
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = var.fargate_spot_weight
  }
}

# ---------------------------------------------------------------------------
# Application security group
# ---------------------------------------------------------------------------

resource "aws_security_group" "tasks" {
  name_prefix = "${var.name}-tasks-"
  description = "ECS tasks for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-tasks" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Application port, from the load balancer only"
  referenced_security_group_id = module.alb.security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Egress is open because the tasks must reach ECR, CloudWatch Logs, Secrets
# Manager and RDS. Narrowing this to prefix lists is possible and is listed in
# the README as a follow-up; it is not free, because ECR endpoints move.
resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound to AWS service endpoints and the database"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Task definition
# ---------------------------------------------------------------------------

locals {
  image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"

  container_definition = {
    name      = var.name
    image     = local.image
    essential = true

    portMappings = [{
      name          = "http"
      containerPort = var.container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # Non-secret configuration.
    environment = [
      for k, v in merge({
        APP_ENV     = var.environment
        APP_VERSION = var.image_tag
        LOG_LEVEL   = var.log_level
        DB_HOST     = var.db_host
        DB_PORT     = tostring(var.db_port)
        DB_NAME     = var.db_name
        DB_SSLMODE  = "require"
      }, var.extra_environment) : { name = k, value = v }
    ]

    # Secret configuration. The trailing :key:: selector pulls a single JSON
    # field out of the RDS-managed secret, so the task receives only the value
    # it needs. The value never appears in the task definition, in Terraform
    # state, or in the ECS console.
    secrets = [
      {
        name      = "DB_USER"
        valueFrom = "${var.db_secret_arn}:username::"
      },
      {
        name      = "DB_PASSWORD"
        valueFrom = "${var.db_secret_arn}:password::"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "app"
      }
    }

    # No container-level healthCheck here on purpose. Fargate ignores the
    # Dockerfile HEALTHCHECK, and the ALB target group check plus the
    # deployment circuit breaker below already detect and replace a bad task.
    # A third health check would only add another thing to keep in sync.

    readonlyRootFilesystem = true
    user                   = "10001:10001"

    linuxParameters = {
      initProcessEnabled = true
    }
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    # ARM64 Graviton is roughly 20 percent cheaper than X86_64 for the same
    # vCPU and memory. The image is built for arm64 in CI, so this costs nothing.
    cpu_architecture = var.cpu_architecture
  }

  container_definitions = jsonencode([local.container_definition])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = var.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  # Give the app time to create its schema and warm up before the load balancer
  # starts counting health check failures against it.
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets = var.private_subnet_ids
    # Private subnets with a NAT route, so no public IP is needed or wanted.
    assign_public_ip = false
    security_groups  = [aws_security_group.tasks.id]
  }

  load_balancer {
    target_group_arn = module.alb.target_groups["app"].arn
    container_name   = var.name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    # Without rollback enabled, a task that crashloops on startup leaves the
    # deployment stuck rather than reverting. This is the cheapest automatic
    # rollback available and it needs no pipeline code at all.
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  dynamic "capacity_provider_strategy" {
    for_each = var.fargate_weight > 0 ? [1] : []

    content {
      capacity_provider = "FARGATE"
      base              = var.fargate_base_count
      weight            = var.fargate_weight
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.fargate_spot_weight > 0 ? [1] : []

    content {
      capacity_provider = "FARGATE_SPOT"
      base              = 0
      weight            = var.fargate_spot_weight
    }
  }

  lifecycle {
    # The CD pipeline, not Terraform, decides which image is deployed, and the
    # autoscaler decides how many tasks run. If Terraform owned either, every
    # terraform apply would silently roll production back to whatever image tag
    # happened to be committed.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [module.alb]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Autoscaling
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.cpu_target_utilization
    # Scale out quickly, scale in slowly. Removing capacity too eagerly turns a
    # traffic dip into a cold start at exactly the wrong moment.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = var.requests_per_target_target > 0 ? 1 : 0

  name               = "${var.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # Request count per target reacts to load before CPU does, which matters
      # for an I/O-bound service whose CPU stays flat while latency climbs.
      resource_label = "${module.alb.arn_suffix}/${module.alb.target_groups["app"].arn_suffix}"
    }

    target_value       = var.requests_per_target_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# ---------------------------------------------------------------------------
# Database access
# ---------------------------------------------------------------------------
# The rule that lets the application reach PostgreSQL lives here rather than in
# the data module so the dependency runs one way. Referencing the task security
# group instead of a CIDR means the grant survives every deploy, scale event and
# subnet change, and that nothing else sharing those subnets inherits access.

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = var.db_security_group_id
  description                  = "PostgreSQL from the ${var.name} ECS tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}
