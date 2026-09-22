# "Claim check" bucket: holds the full PR diff. EventBridge and Step
# Functions only carry lightweight metadata + this bucket's key, never the
# full diff payload.
resource "aws_s3_bucket" "pr_diffs" {
  bucket        = "${var.project_name}-pr-diffs"
  force_destroy = true

  tags = local.common_tags
}

# Diffs are only needed for the duration of a review; without this, objects
# would accumulate in the bucket indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "pr_diffs" {
  bucket = aws_s3_bucket.pr_diffs.id

  rule {
    id     = "expire-diffs-after-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# Published at /${var.project_name}/s3/pr-diffs-bucket-name, so
# codereview-lambda can populate its DIFF_BUCKET environment variable
# without hardcoding the bucket name.
resource "aws_ssm_parameter" "pr_diffs_bucket_name" {
  name  = "/${var.project_name}/s3/pr-diffs-bucket-name"
  type  = "String"
  value = aws_s3_bucket.pr_diffs.bucket

  tags = local.common_tags
}
