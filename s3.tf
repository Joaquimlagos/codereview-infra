# "Claim check" bucket: holds the full PR diff. EventBridge and Step
# Functions only carry lightweight metadata + this bucket's key, never the
# full diff payload.
resource "aws_s3_bucket" "pr_diffs" {
  bucket        = "${var.project_name}-pr-diffs"
  force_destroy = true
}
