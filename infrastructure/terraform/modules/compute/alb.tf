# ---------------------------------------------------------------------------
# ALB access logs
# ---------------------------------------------------------------------------
# The ALB is the only place a true access log exists --
# ECS tasks never see the client's real connection. The bucket lives here rather
# than in the observability module so that the observability module can depend
# on the ALB without a dependency cycle.

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${var.name}-alb-logs-"
  force_destroy = var.log_bucket_force_destroy

  tags = merge(var.tags, { Name = "${var.name}-alb-logs" })
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# trivy:ignore:AWS-0132
# Accepted, and not fixable: ALB access-log delivery supports SSE-S3 only.
# Configuring SSE-KMS here does not fail loudly -- it silently stops log
# delivery, which looks exactly like "access logging was never enabled".
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      # ALB access log delivery supports SSE-S3 only; SSE-KMS silently fails to
      # deliver, which looks exactly like "logging is not enabled".
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    # S3 rejects any configuration whose expiration is not strictly greater than
    # its transition, so the transition is omitted when retention is at or below
    # the transition threshold. That is also the economically correct choice:
    # Infrequent Access bills a 30-day minimum duration per object, so moving an
    # object to IA and deleting it days later costs more than leaving it in
    # Standard.
    dynamic "transition" {
      for_each = var.access_log_retention_days > var.access_log_transition_days ? [1] : []

      content {
        days          = var.access_log_transition_days
        storage_class = "STANDARD_IA"
      }
    }

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "AllowALBLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

locals {
  https_enabled = var.certificate_arn != null

  # With a certificate, port 80 exists only to redirect. Without one (the
  # default in environments with no registered domain), port 80 forwards
  # directly and the README says so plainly rather than pretending otherwise.
  # Built with merge() rather than a plain conditional: a ternary requires both
  # branches to have the same object type, and these two deliberately differ --
  # one redirects, the other forwards.
  http_listener = merge(
    {
      port     = 80
      protocol = "HTTP"
    },
    local.https_enabled ? {
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
      } : {
      forward = { target_group_key = "app" }
    },
  )

  https_listener = local.https_enabled ? {
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = var.certificate_arn
      ssl_policy      = var.ssl_policy
      forward         = { target_group_key = "app" }
    }
  } : {}
}

# trivy:ignore:AWS-0053
# Accepted: the load balancer is internet-facing because this is a public web
# service. That is the requirement, not an oversight.
#
# trivy:ignore:AWS-0054
# Accepted conditionally: the HTTP listener forwards directly only when no ACM
# certificate is supplied, which is the case in environments with no registered
# domain. Set certificate_arn and port 80 becomes a 301 to a TLS 1.3 listener.
# See docs/adr/0007-tls-termination.md.
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.1"

  name    = var.name
  vpc_id  = var.vpc_id
  subnets = var.public_subnet_ids

  internal                   = false
  enable_deletion_protection = var.enable_deletion_protection
  # Drop requests with malformed headers rather than forwarding them to the app;
  # header smuggling is the classic way past a path-based authorization rule.
  drop_invalid_header_fields = true
  enable_http2               = true
  idle_timeout               = 60

  access_logs = {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  security_group_ingress_rules = merge(
    {
      http = {
        from_port   = 80
        to_port     = 80
        ip_protocol = "tcp"
        description = "HTTP from the internet"
        cidr_ipv4   = "0.0.0.0/0"
      }
    },
    local.https_enabled ? {
      https = {
        from_port   = 443
        to_port     = 443
        ip_protocol = "tcp"
        description = "HTTPS from the internet"
        cidr_ipv4   = "0.0.0.0/0"
      }
    } : {},
  )

  # The load balancer may talk to the application tier and to nothing else.
  security_group_egress_rules = {
    to_tasks = {
      from_port                    = var.container_port
      to_port                      = var.container_port
      ip_protocol                  = "tcp"
      description                  = "Forward to ECS tasks"
      referenced_security_group_id = aws_security_group.tasks.id
    }
  }

  listeners = merge({ http = local.http_listener }, local.https_listener)

  target_groups = {
    app = {
      name_prefix = substr(var.name, 0, 6)
      protocol    = "HTTP"
      port        = var.container_port
      # "ip" rather than "instance": Fargate tasks get their own ENI and are
      # registered by IP, and ECS does the registering.
      target_type = "ip"
      # ECS owns target registration. A static attachment here would fight the
      # service and leave stale targets behind on every deploy.
      create_attachment = false

      deregistration_delay = 30

      health_check = {
        enabled             = true
        path                = var.health_check_path
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 15
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  }

  tags = var.tags
}
