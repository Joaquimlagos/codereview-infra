# ARNs of the Lambda functions that implement each pipeline state. This repo
# never provisions Lambda resources itself — those live in the
# `codereview-lambda` repository. We only construct the ARN from the AWS
# account/region + an agreed-upon function name, so Step Functions and IAM
# can reference them without any cross-repo state coupling (no
# terraform_remote_state, no ordering dependency between the two repos' applies).
data "aws_caller_identity" "current" {}

locals {
  lambda_arn_prefix = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function"

  route_model_lambda_arn      = "${local.lambda_arn_prefix}:${var.route_model_lambda_name}"
  retrieve_context_lambda_arn = "${local.lambda_arn_prefix}:${var.retrieve_context_lambda_name}"
  invoke_llm_lambda_arn       = "${local.lambda_arn_prefix}:${var.invoke_llm_lambda_name}"
  post_comment_lambda_arn     = "${local.lambda_arn_prefix}:${var.post_comment_lambda_name}"
}
