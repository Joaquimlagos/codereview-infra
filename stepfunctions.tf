data "aws_iam_policy_document" "state_machine_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${var.project_name}-state-machine-role"
  assume_role_policy = data.aws_iam_policy_document.state_machine_assume_role.json
}

# Least privilege: the State Machine can only invoke the 4 pipeline Lambdas,
# nothing else. These functions are owned and deployed by codereview-lambda;
# we only reference their ARNs (see lambda_arns.tf).
data "aws_iam_policy_document" "state_machine_invoke_lambdas" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      local.route_model_lambda_arn,
      local.retrieve_context_lambda_arn,
      local.invoke_llm_lambda_arn,
      local.post_comment_lambda_arn,
    ]
  }
}

resource "aws_iam_role_policy" "state_machine_invoke_lambdas" {
  name   = "${var.project_name}-state-machine-invoke-lambdas"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine_invoke_lambdas.json
}

resource "aws_sfn_state_machine" "pr_review" {
  name     = "${var.project_name}-pr-review"
  role_arn = aws_iam_role.state_machine.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/statemachine/definition.asl.json.tpl", {
    route_model_arn      = local.route_model_lambda_arn
    retrieve_context_arn = local.retrieve_context_lambda_arn
    invoke_llm_arn       = local.invoke_llm_lambda_arn
    post_comment_arn     = local.post_comment_lambda_arn
  })
}
