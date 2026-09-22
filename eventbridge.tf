# Event bus dedicated to the PR review pipeline. In production, GitHub
# Actions in the `codereview-app` repo publishes the "PRReviewRequested"
# event here, containing only PR metadata + the diff key in the claim-check
# bucket.
resource "aws_cloudwatch_event_bus" "pr_review" {
  name = "${var.project_name}-bus"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "pr_review_requested" {
  name           = "${var.project_name}-pr-review-requested"
  event_bus_name = aws_cloudwatch_event_bus.pr_review.name

  event_pattern = jsonencode({
    source      = ["codereview.app"]
    detail-type = ["PRReviewRequested"]
  })

  tags = local.common_tags
}

data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_start_execution" {
  name               = "${var.project_name}-eventbridge-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json

  tags = local.common_tags
}

# Least privilege: EventBridge can only start executions of this specific
# State Machine.
data "aws_iam_policy_document" "eventbridge_start_execution" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pr_review.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_start_execution" {
  name   = "${var.project_name}-eventbridge-start-execution"
  role   = aws_iam_role.eventbridge_start_execution.id
  policy = data.aws_iam_policy_document.eventbridge_start_execution.json
}

resource "aws_cloudwatch_event_target" "pr_review_state_machine" {
  rule           = aws_cloudwatch_event_rule.pr_review_requested.name
  event_bus_name = aws_cloudwatch_event_bus.pr_review.name
  arn            = aws_sfn_state_machine.pr_review.arn
  role_arn       = aws_iam_role.eventbridge_start_execution.arn

  # Forward only the event's "detail" (metadata + S3 pointer) as the State
  # Machine input — never the full diff payload.
  input_path = "$.detail"
}
