# Container registry.
#
# One repository for the platform, not one per environment. The pipeline builds
# an image once and promotes that same artifact through staging to production,
# so "production runs exactly what staging ran" is only true if both pull the
# same bytes from the same place. A repository per environment quietly invites
# a rebuild for production, which is a different artifact however identical the
# inputs look.
#
# It lives here rather than in an environment because it outlives them: tearing
# an environment down should not destroy the images you would roll back to.

resource "aws_ecr_repository" "app" {
  name = var.resource_name_prefix

  # Immutable tags mean a given tag can never be re-pointed at different bytes.
  # Combined with deploying by sha-<commit> tag, this makes "which code is in
  # production" answerable from the tag alone.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Tagging comes from the provider's default_tags in versions.tf.
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent ${var.keep_last_images} release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
