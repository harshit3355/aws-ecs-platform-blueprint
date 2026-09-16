# ---------------------------------------------------------------------------
# Load balancer alarms -- the user-visible symptoms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name        = "${var.name}-alb-5xx"
  alarm_description = "The load balancer is returning 5xx responses to clients."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { LoadBalancer = var.alb_arn_suffix }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name        = "${var.name}-target-5xx"
  alarm_description = "The application itself is returning 5xx responses."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_latency" {
  alarm_name        = "${var.name}-target-latency-p99"
  alarm_description = "p99 response time from the application exceeded the objective."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p99"
  period             = 300
  # Two consecutive periods, so a single slow batch job does not page anyone.
  evaluation_periods  = 2
  threshold           = var.latency_p99_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.name}-unhealthy-targets"
  alarm_description = "One or more ECS tasks are failing the load balancer health check."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # Missing data here means the target group is reporting nothing at all, which
  # is worse than an unhealthy target, not better.
  treat_missing_data = "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}

# ---------------------------------------------------------------------------
# ECS alarms -- the compute tier
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name        = "${var.name}-ecs-cpu-high"
  alarm_description = "Service CPU sustained above target. The autoscaler should already be reacting; this fires if it cannot."

  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.ecs_cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name        = "${var.name}-ecs-memory-high"
  alarm_description = "Service memory sustained above threshold. Memory pressure ends as an OOM kill, which looks like a random task restart."

  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.ecs_memory_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  alarm_name        = "${var.name}-ecs-no-running-tasks"
  alarm_description = "The service has fewer running tasks than its floor. This is an outage."

  # ECS/ContainerInsights, not AWS/ECS. The AWS/ECS namespace publishes only
  # CPUUtilization, MemoryUtilization and LiveTaskCount; RunningTaskCount comes
  # from Container Insights. Pointing an alarm at a metric that does not exist
  # produces no datapoints, and combined with treat_missing_data = "breaching"
  # below that is a permanently firing alarm -- a false positive that never
  # clears, which is the fastest way to train everyone to ignore the channel.
  #
  # Note the asymmetry: "breaching" turns a wrong metric name into a permanent
  # page, while "notBreaching" would have hidden it silently and left the real
  # outage undetected. Neither setting is safe against a typo; only the correct
  # namespace is.
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.min_running_tasks
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.tags
}
