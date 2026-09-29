# CloudWatch dashboard for the review pipeline's speed: the state machine end to end, each
# Lambda's duration, and one table row per routing decision, model call and retrieval.
#
# Lambda function names are taken from the ARNs this repo already reads from SSM
# (lambda_arns.tf), so no new cross-repo parameter is needed. The Logs Insights queries in
# dashboard/*.insights read the JSON lines codereview-lambda logs; their fields are
# documented in that repo's README, "Structured logs".
locals {
  dashboard_function_names = {
    route_model      = element(split(":", local.route_model_lambda_arn), 6)
    retrieve_context = element(split(":", local.retrieve_context_lambda_arn), 6)
    invoke_llm       = element(split(":", local.invoke_llm_lambda_arn), 6)
    post_comment     = element(split(":", local.post_comment_lambda_arn), 6)
  }

  dashboard_log_group = {
    for state, name in local.dashboard_function_names : state => "/aws/lambda/${name}"
  }

  dashboard_text = <<-EOT
    ## ${var.project_name} PR review pipeline

    A pull request on `codereview-app` uploads its diff to S3 and publishes `PRReviewRequested`. EventBridge starts the state machine: **RouteModel** asks Jev for the complexity tier and whether project context is needed, **RetrieveContext** (only if needed) ranks the per-method RAG index against the diff, **InvokeLLM** tries the tier's models in order, and **PostComment** posts the review on the PR.

    Tiers: low / medium `Groq → Cerebras → Gemini` · high `Cerebras → Groq → Gemini`. Tables read the JSON log lines documented in [codereview-lambda's "Structured logs"](https://github.com/Joaquimlagos/codereview-lambda#structured-logs). Lambda logs are kept 7 days.
  EOT
}

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project_name}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions: execution time"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.pr_review.arn, { stat = "Average", label = "mean" }],
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.pr_review.arn, { stat = "p90", label = "p90" }],
          ]
          yAxis = { left = { label = "ms", showUnits = false } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions: executions"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.pr_review.arn, { label = "succeeded" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.pr_review.arn, { label = "failed" }],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 5
        properties = {
          title  = "PostComment: time from execution start to posted review"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.dashboard_log_group.post_comment}' | ${file("${path.module}/dashboard/reviews_posted.insights")}"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 11
        width  = 24
        height = 6
        properties = {
          title  = "Lambda duration (average)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            for state, name in local.dashboard_function_names :
            ["AWS/Lambda", "Duration", "FunctionName", name, { label = name }]
          ]
          yAxis = { left = { label = "ms", showUnits = false } }
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 17
        width  = 24
        height = 5
        properties = {
          title  = "RouteModel: Jev decisions"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.dashboard_log_group.route_model}' | ${file("${path.module}/dashboard/route_decisions.insights")}"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 22
        width  = 24
        height = 7
        properties = {
          title  = "InvokeLLM: every model call"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.dashboard_log_group.invoke_llm}' | ${file("${path.module}/dashboard/llm_calls.insights")}"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 29
        width  = 24
        height = 5
        properties = {
          title  = "RetrieveContext: retrieval per review"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.dashboard_log_group.retrieve_context}' | ${file("${path.module}/dashboard/rag_queries.insights")}"
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 34
        width  = 24
        height = 4
        properties = {
          markdown = local.dashboard_text
        }
      },
    ]
  })
}
