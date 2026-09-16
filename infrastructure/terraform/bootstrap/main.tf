# Terraform state backend.
#
# Chicken and egg: this configuration creates the bucket that every other
# configuration uses as its backend, so it necessarily keeps *local* state. It is
# applied once, by hand, and then effectively never again. Its own state file is
# committed nowhere -- losing it costs an import, not an outage.

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # This bucket is the only copy of the record of what exists in the account.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  # Versioning is the actual disaster-recovery story for Terraform state: a
  # corrupted or truncated state file is recovered by restoring the previous
  # object version.
  versioning_configuration {
    status = "Enabled"
  }
}

# Accepted for now: SSE-S3 rather than a customer-managed key. A CMK would add
# per-request KMS charges and, more importantly, a key whose deletion makes
# every state file unreadable -- a failure mode worse than the one it prevents,
# until key administration is properly owned. Revisit when the account has a
# managed KMS story.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    # Keep enough history to recover from a bad apply without paying to store
    # every version of a file that changes on every single run.
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any plaintext access. State contains resource attributes that are
# sensitive even when secrets themselves are kept in Secrets Manager.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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
