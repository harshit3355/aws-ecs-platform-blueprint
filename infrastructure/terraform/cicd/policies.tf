# ---------------------------------------------------------------------------
# Build role -- may push images and nothing else
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action accepts no resource ARN
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    # The repository is defined in this same configuration, so reference its ARN
    # rather than matching a name pattern. An earlier version scoped this to
    # "<prefix>-*", which matched the old per-environment repositories and
    # silently stopped matching when they were replaced by a single repository
    # named exactly "<prefix>". A policy that grants nothing fails at push time,
    # not at apply time, which is the worst place to find out.
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "ecr-push"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# ---------------------------------------------------------------------------
# Deploy role -- may roll a service, and read what it needs to do so
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy" {
  # The deploy action reads the live task definition and edits only the image,
  # so everything Terraform set on the container is preserved. That read is
  # therefore a requirement, not a convenience.
  statement {
    sid    = "ReadEcsState"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"] # Describe/List do not accept resource ARNs uniformly
  }

  # RegisterTaskDefinition genuinely has no resource ARN in IAM -- this cannot
  # be scoped, and any claim otherwise would be wrong. What bounds it is the
  # PassRole statement below: a task definition is only dangerous if it can run
  # as a privileged role, and this role may pass only the platform's own roles.
  statement {
    sid       = "RegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "RollService"
    effect    = "Allow"
    actions   = ["ecs:UpdateService"]
    resources = ["arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:service/${var.resource_name_prefix}-*/*"]
  }

  statement {
    sid       = "PassPlatformRolesToEcsOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.resource_name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Read-only on ECR so a deploy can confirm the tag it is about to ship exists.
  # Split in two because GetAuthorizationToken accepts no resource ARN, while
  # the read actions do -- lumping them together would have scoped both to "*".
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "ConfirmImageExists"
    effect    = "Allow"
    actions   = ["ecr:DescribeImages", "ecr:BatchGetImage"]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "ecs-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
