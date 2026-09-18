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
