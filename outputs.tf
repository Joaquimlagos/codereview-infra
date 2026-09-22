output "pr_diffs_bucket" {
  description = "Name of the S3 bucket used as claim check for PR diffs."
  value       = aws_s3_bucket.pr_diffs.bucket
}

output "event_bus_name" {
  description = "Name of the EventBridge event bus."
  value       = aws_cloudwatch_event_bus.pr_review.name
}

output "event_rule_name" {
  description = "Name of the EventBridge rule that triggers the State Machine."
  value       = aws_cloudwatch_event_rule.pr_review_requested.name
}

output "state_machine_arn" {
  description = "ARN of the PR review pipeline's State Machine."
  value       = aws_sfn_state_machine.pr_review.arn
}

output "secret_arns" {
  description = "ARNs of the Secrets Manager secrets, keyed by secret key (typesafe_api_key, gemini_api_key, github_token). Use with `aws secretsmanager put-secret-value` to set real values after deploy."
  value       = { for key, secret in aws_secretsmanager_secret.this : key => secret.arn }
}

output "secret_arn_ssm_parameters" {
  description = "SSM parameter names where each secret's ARN is published, for codereview-lambda to read."
  value       = { for key, param in aws_ssm_parameter.secret_arn : key => param.name }
}

output "pr_diffs_bucket_ssm_parameter" {
  description = "SSM parameter name where the PR diffs bucket name is published, for codereview-lambda to populate DIFF_BUCKET."
  value       = aws_ssm_parameter.pr_diffs_bucket_name.name
}

output "github_actions_pr_review_role_arn" {
  description = "ARN of the IAM role codereview-app's GitHub Actions workflow assumes via OIDC (aws-actions/configure-aws-credentials role-to-assume)."
  value       = aws_iam_role.github_actions_pr_review.arn
}
