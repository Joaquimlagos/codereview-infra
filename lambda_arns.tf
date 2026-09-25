# ARNs of the Lambda functions that implement each pipeline state. This repo
# never provisions Lambda resources itself — those live in the
# `codereview-lambda` repository.
#
# DEPLOY ORDER DEPENDENCY: `codereview-lambda` must be deployed BEFORE this
# repo, because the data sources below read SSM parameters that only exist
# once that repo has published them post-deploy:
#   /${var.project_name}/lambda/route-model/arn
#   /${var.project_name}/lambda/retrieve-context/arn
#   /${var.project_name}/lambda/invoke-llm/arn
#   /${var.project_name}/lambda/post-comment/arn
# e.g. /codereview/lambda/route-model/arn
#
# We read those parameters here instead of using terraform_remote_state, so
# there is no cross-repo state *coupling* — but the ordering dependency
# itself is real: `terraform plan`/`apply` in this repo will fail with a
# "parameter not found" error if codereview-lambda hasn't been deployed yet.
# Set var.lambda_arns_override (see variables.tf) to bypass the SSM lookup
# and unblock local plan/apply before that repo exists.

locals {
  lambda_ssm_paths = {
    route_model      = "/${var.project_name}/lambda/route-model/arn"
    retrieve_context = "/${var.project_name}/lambda/retrieve-context/arn"
    invoke_llm       = "/${var.project_name}/lambda/invoke-llm/arn"
    post_comment     = "/${var.project_name}/lambda/post-comment/arn"
  }
}

data "aws_ssm_parameter" "route_model_lambda_arn" {
  count = contains(keys(var.lambda_arns_override), "route_model") ? 0 : 1
  name  = local.lambda_ssm_paths.route_model
}

data "aws_ssm_parameter" "retrieve_context_lambda_arn" {
  count = contains(keys(var.lambda_arns_override), "retrieve_context") ? 0 : 1
  name  = local.lambda_ssm_paths.retrieve_context
}

data "aws_ssm_parameter" "invoke_llm_lambda_arn" {
  count = contains(keys(var.lambda_arns_override), "invoke_llm") ? 0 : 1
  name  = local.lambda_ssm_paths.invoke_llm
}

data "aws_ssm_parameter" "post_comment_lambda_arn" {
  count = contains(keys(var.lambda_arns_override), "post_comment") ? 0 : 1
  name  = local.lambda_ssm_paths.post_comment
}

# The provider marks every aws_ssm_parameter value sensitive, which would
# hide the whole State Machine definition in plans. These are ARNs, not
# secrets, so the mark is dropped on the SSM branch (the override branch is
# never sensitive to begin with).
locals {
  route_model_lambda_arn = try(
    var.lambda_arns_override["route_model"],
    nonsensitive(data.aws_ssm_parameter.route_model_lambda_arn[0].value),
  )

  retrieve_context_lambda_arn = try(
    var.lambda_arns_override["retrieve_context"],
    nonsensitive(data.aws_ssm_parameter.retrieve_context_lambda_arn[0].value),
  )

  invoke_llm_lambda_arn = try(
    var.lambda_arns_override["invoke_llm"],
    nonsensitive(data.aws_ssm_parameter.invoke_llm_lambda_arn[0].value),
  )

  post_comment_lambda_arn = try(
    var.lambda_arns_override["post_comment"],
    nonsensitive(data.aws_ssm_parameter.post_comment_lambda_arn[0].value),
  )
}
