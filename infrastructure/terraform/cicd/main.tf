# Federated access for GitHub Actions.
#
# Two roles, deliberately, rather than one:
#
#   meridian-github-build   push images to ECR. Trusted from the main branch.
#   meridian-github-deploy  roll ECS services. Trusted ONLY from a declared
#                           GitHub Environment.
#
# The split exists because the subject claim differs by job. A job that declares
# `environment: production` presents
# repo:<owner>/<repo>:environment:production; a job that does not presents
# repo:<owner>/<repo>:ref:refs/heads/main. Trusting the branch form in a role
# that can update ECS would mean any future main-branch workflow could roll
# production. Trusting only the environment form means reaching the deploy role
# requires passing through that environment's protection rules -- which is where
# the production approval gate lives.

data "aws_caller_identity" "current" {}

# The OIDC provider is an account-level singleton: there can be exactly one per
# issuer. It is read, never created, so this configuration composes with
# whatever already exists in the account instead of colliding with it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  issuer = "token.actions.githubusercontent.com"

  # GitHub is rolling out immutable subject claims, where the subject embeds the
  # numeric owner and repository IDs rather than their names:
  #
  #   repo:owner@1234/name@5678:ref:refs/heads/main
  #
  # That is strictly better -- renaming an account cannot silently transfer
  # trust to whoever claims the old name -- but it means the repo:owner/name
  # form used by every guide written before the rollout produces a trust policy
  # that never matches. The failure is "Not authorized to perform
  # sts:AssumeRoleWithWebIdentity", which reads like a permissions problem
  # rather than a string mismatch.
  subject_prefix = coalesce(var.github_subject_prefix, "repo:${var.github_repository}")

  build_subjects = ["${local.subject_prefix}:ref:refs/heads/main"]

  deploy_subjects = [
    for env in var.deploy_environments :
    "${local.subject_prefix}:environment:${env}"
  ]
}

# ---------------------------------------------------------------------------
# Trust policies
# ---------------------------------------------------------------------------
# StringEquals, never StringLike. A wildcard here is not a convenience, it is a
# hole: the subject claim carries the owner and repository in one string, so
# "repo:acme*" also matches "repo:acmeanything/whatever", and GitHub account
# names are globally unique and free to register.

data "aws_iam_policy_document" "build_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = local.build_subjects
    }
  }
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = local.deploy_subjects
    }
  }
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "build" {
  name                 = "${var.resource_name_prefix}-github-build"
  description          = "GitHub Actions: build and push container images for ${var.github_repository}"
  assume_role_policy   = data.aws_iam_policy_document.build_assume.json
  max_session_duration = var.max_session_seconds
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.resource_name_prefix}-github-deploy"
  description          = "GitHub Actions: roll ECS services for ${var.github_repository}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = var.max_session_seconds
}
