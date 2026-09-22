# OIDC federation between GitHub Actions (codereview-app) and AWS. Lets the
# CI workflow assume an AWS role via short-lived, keyless credentials — no
# static AWS access keys stored as GitHub secrets.
#
# The provider's thumbprint is fetched from GitHub's own TLS certificate
# chain instead of being hardcoded, so it never goes stale if GitHub rotates
# its certificate.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[length(data.tls_certificate.github_actions.certificates) - 1].sha1_fingerprint]

  tags = local.common_tags
}

# Trust policy: only the specific codereview-app repo (any branch/event, for
# now) can assume this role, and only via the sts.amazonaws.com audience.
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_pr_review" {
  name               = "${var.project_name}-github-actions-pr-review"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = local.common_tags
}

# Least privilege: this role only uploads the PR diff and fires the review
# event — nothing else. events:PutEvents is scoped to this repo's custom
# event bus (never the default bus, never a wildcard); s3:PutObject is
# scoped to the diffs bucket's objects.
data "aws_iam_policy_document" "github_actions_pr_review" {
  statement {
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.pr_review.arn]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.pr_diffs.arn}/*"]
  }
}

resource "aws_iam_role_policy" "github_actions_pr_review" {
  name   = "${var.project_name}-github-actions-pr-review"
  role   = aws_iam_role.github_actions_pr_review.id
  policy = data.aws_iam_policy_document.github_actions_pr_review.json
}
