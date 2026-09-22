# Secrets consumed by codereview-lambda functions. This repo only creates
# the empty secret containers and publishes their ARNs to SSM — it never
# sets real values and never grants read access to them. Real values are set
# manually after deploy via the console or `aws secretsmanager
# put-secret-value`. codereview-lambda is responsible for reading the ARN
# from SSM and granting each secret's read permission only to the execution
# role of the specific function that needs it (RouteModel reads
# typesafe_api_key, InvokeLLM reads gemini_api_key, PostComment reads
# github_token).
locals {
  managed_secrets = {
    typesafe_api_key = {
      name        = "${var.project_name}/typesafe-api-key"
      description = "TypeSafe/Jev API key, read by the RouteModel Lambda in codereview-lambda."
    }
    gemini_api_key = {
      name        = "${var.project_name}/gemini-api-key"
      description = "Gemini API key, read by the InvokeLLM Lambda in codereview-lambda."
    }
    github_token = {
      name        = "${var.project_name}/github-token"
      description = "GitHub token used to post the review comment back to the PR, read by the PostComment Lambda in codereview-lambda."
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.managed_secrets

  name        = each.value.name
  description = each.value.description

  tags = local.common_tags
}

# Published at /${var.project_name}/secrets/<secret-key>-arn, e.g.
# /codereview/secrets/typesafe-api-key-arn — the same cross-repo pattern
# used for Lambda ARNs in lambda_arns.tf, so codereview-lambda never has to
# hardcode a secret ARN.
resource "aws_ssm_parameter" "secret_arn" {
  for_each = local.managed_secrets

  name  = "/${var.project_name}/secrets/${replace(each.key, "_", "-")}-arn"
  type  = "String"
  value = aws_secretsmanager_secret.this[each.key].arn

  tags = local.common_tags
}
