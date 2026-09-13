# Alerting and the AWS-side dashboard.
#
# Prometheus and Grafana (see observability/ at the repo root) cover the
# application's own RED metrics. This module covers everything Prometheus cannot
# see from inside the container: the managed services, the load balancer, and
# the logs.

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Notification fan-out
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_addresses)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# HTTPS subscription to a Slack incoming webhook. Kept optional because the
# webhook URL is itself a credential and does not belong in tfvars -- pass it
# through TF_VAR_slack_webhook_url from the pipeline's secret store.
resource "aws_sns_topic_subscription" "slack" {
  count = var.slack_webhook_url == null ? 0 : 1

  topic_arn              = aws_sns_topic.alerts.arn
  protocol               = "https"
  endpoint               = var.slack_webhook_url
  endpoint_auto_confirms = true
}

# ---------------------------------------------------------------------------
# Log-derived metrics
# ---------------------------------------------------------------------------
# The application logs one JSON object per line, which is why this filter can be
# a structured pattern rather than a substring match on free text. A substring
# filter would also match the word ERROR inside a user-supplied string.

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.name}-app-errors"
  log_group_name = var.app_log_group_name
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name      = "ApplicationErrors"
    namespace = var.metric_namespace
    value     = "1"
    unit      = "Count"
    # Without an explicit zero default the alarm sits in INSUFFICIENT_DATA
    # whenever the service is healthy, which is exactly when you want to be
    # able to tell "no errors" apart from "no data".
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.name}-application-errors"
  alarm_description   = "Application emitted ERROR-level logs. Check the ${var.app_log_group_name} log group."
  namespace           = var.metric_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.app_errors.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.error_log_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}
