# Shared artifacts bucket, split by prefix instead of by bucket — one
# "configuration boundary" (lifecycle rules, IAM scoping) per prefix keeps
# this simpler than provisioning separate buckets:
#   prs/{pr}/{sha}.diff        — PR diff claim check (EventBridge/Step
#                                 Functions only carry the S3 key, never the
#                                 full diff payload). Expires after 30 days.
#   index/develop/index.json   — RAG embeddings index, built by codereview-app
#                                 and read by RetrieveContext. Never expires.
#   terraform-state/           — this repo's remote state (see backend.tf).
#                                 Never expires; not writable by the
#                                 codereview-app OIDC role.
#
# No force_destroy: `terraform destroy` fails on a non-empty bucket instead
# of silently wiping everything in it — including the state file this
# configuration is running from. Emptying the bucket is a deliberate manual
# step (see "Tear down" in the README).
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project_name}-artifacts"

  tags = local.common_tags
}

# Lets a corrupted or wrongly overwritten object — the Terraform state in
# particular — be restored from a previous version.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Only the prs/ prefix expires — a bucket-wide rule here would silently wipe
# the RAG index and the Terraform state. With versioning enabled,
# `expiration` alone only adds a delete marker and keeps the old diff as a
# noncurrent version forever, so noncurrent versions of prs/ objects are
# expired too; otherwise diffs would accumulate indefinitely again.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  depends_on = [aws_s3_bucket_versioning.artifacts]

  rule {
    id     = "expire-pr-diffs-after-30-days"
    status = "Enabled"

    filter {
      prefix = "prs/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# Published at /${var.project_name}/s3/artifacts-bucket-name, so
# codereview-lambda and codereview-app can populate their bucket-name env
# vars without hardcoding it.
resource "aws_ssm_parameter" "artifacts_bucket_name" {
  name  = "/${var.project_name}/s3/artifacts-bucket-name"
  type  = "String"
  value = aws_s3_bucket.artifacts.bucket

  tags = local.common_tags
}
