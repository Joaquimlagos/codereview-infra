variable "project_name" {
  description = "Prefix used in the name of every resource created by this repository."
  type        = string
  default     = "codereview"
}

variable "aws_region" {
  description = "AWS region used by the provider."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name. Used for tagging."
  type        = string
  default     = "local"
}

variable "github_owner" {
  description = "GitHub account/organization that owns codereview-app. Scopes the GitHub Actions OIDC trust policy so only that account's repo can assume the CI role."
  type        = string
}

variable "github_repo" {
  description = "Name of the GitHub repository whose Actions workflow is allowed to assume the CI role via OIDC."
  type        = string
  default     = "codereview-app"
}

# Manual overrides for the Lambda ARNs normally looked up from SSM Parameter
# Store (see lambda_arns.tf). Keyed by state name: route_model,
# retrieve_context, invoke_llm, post_comment. Any key present here takes
# priority over the SSM lookup for that state.
#
# This exists so `terraform plan`/`apply` works even before codereview-lambda
# exists and has published its parameters — set fake ARNs here in a local
# .tfvars (never committed) to unblock testing this repo in isolation. Leave
# empty (the default) once codereview-lambda is deployed and publishing real
# parameters.
variable "lambda_arns_override" {
  description = "Optional manual overrides for Lambda ARNs, keyed by state name. Takes priority over the SSM Parameter Store lookup."
  type        = map(string)
  default     = {}
}
