# ---------------------------------------------------------------------------
# CloudWatch dashboard
# ---------------------------------------------------------------------------
# This is the AWS-side counterpart to the two Grafana dashboards. It exists
# because Grafana cannot see managed-service metrics: RDS internals, ECS task
# counts, and what the load balancer observed before a request ever reached the
# application. Together the three dashboards cover the full request path.

locals {
  dashboard_body = jsonencode({
    start          = "-PT3H"
    periodOverride = "auto"
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2,
        properties = {
          markdown = "# ${var.name} - platform overview\nApplication RED metrics live in Grafana (`platform/observability/grafana/dashboards/service-red.json`). This dashboard covers the AWS-managed layers: load balancer, ECS and RDS."
        }
      },

      # ---- edge ----
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6,
        properties = {
          title  = "ALB - request rate and errors"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { label = "requests" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { label = "target 5xx", color = "#d62728" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { label = "elb 5xx", color = "#ff7f0e" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { label = "target 4xx" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6,
        properties = {
          title  = "ALB - target response time"
          region = data.aws_region.current.region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { label = "seconds", showUnits = false } }
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          annotations = {
            horizontal = [{
              label = "p99 objective"
              value = var.latency_p99_threshold_seconds
            }]
          }
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6,
        properties = {
          title  = "ALB - target health"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { label = "healthy", color = "#2ca02c" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { label = "unhealthy", color = "#d62728" }],
          ]
        }
      },

      # ---- compute ----
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6,
        properties = {
          title  = "ECS - CPU and memory utilisation"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          yAxis  = { left = { min = 0, max = 100, label = "percent", showUnits = false } }
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { label = "cpu" }],
            [".", "MemoryUtilization", ".", ".", ".", ".", { label = "memory" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6,
        properties = {
          title  = "ECS - running vs desired tasks"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { label = "running" }],
            [".", "DesiredTaskCount", ".", ".", ".", ".", { label = "desired" }],
            [".", "PendingTaskCount", ".", ".", ".", ".", { label = "pending" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6,
        properties = {
          title  = "ECS - ephemeral storage and network"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "EphemeralStorageUtilized", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { label = "ephemeral storage used" }],
            [".", "NetworkRxBytes", ".", ".", ".", ".", { label = "net rx", yAxis = "right" }],
            [".", "NetworkTxBytes", ".", ".", ".", ".", { label = "net tx", yAxis = "right" }],
          ]
        }
      },

      # ---- data ----
      {
        type = "metric", x = 0, y = 14, width = 8, height = 6,
        properties = {
          title  = "RDS - CPU and connections"
          region = data.aws_region.current.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_identifier, { stat = "Average", label = "cpu percent" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Maximum", label = "connections", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 14, width = 8, height = 6,
        properties = {
          title  = "RDS - storage and memory headroom"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Minimum"
          period = 300
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_identifier, { label = "free storage" }],
            [".", "FreeableMemory", ".", ".", { label = "freeable memory" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 14, width = 8, height = 6,
        properties = {
          title  = "RDS - IOPS and latency"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", var.rds_instance_identifier, { label = "read iops" }],
            [".", "WriteIOPS", ".", ".", { label = "write iops" }],
            [".", "ReadLatency", ".", ".", { label = "read latency", yAxis = "right" }],
            [".", "WriteLatency", ".", ".", { label = "write latency", yAxis = "right" }],
          ]
        }
      },

      # ---- logs ----
      {
        type = "log", x = 0, y = 20, width = 24, height = 7,
        properties = {
          title  = "Recent application errors"
          region = data.aws_region.current.region
          view   = "table"
          # Structured JSON logs make this a field query rather than a substring
          # search, so it cannot be fooled by the word ERROR inside a message.
          query = "SOURCE '${var.app_log_group_name}' | fields @timestamp, level, logger, message, error\n| filter level = 'ERROR'\n| sort @timestamp desc\n| limit 50"
        }
      },
    ]
  })
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.name}-platform"
  dashboard_body = local.dashboard_body
}
