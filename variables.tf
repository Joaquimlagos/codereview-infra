variable "project_name" {
  description = "Prefix used in the name of every resource created by this repository."
  type        = string
  default     = "codereview"
}

variable "aws_region" {
  description = "AWS region (fake, only used to satisfy the provider when running against LocalStack)."
  type        = string
  default     = "us-east-1"
}

variable "localstack_endpoint" {
  description = "LocalStack endpoint for all services used."
  type        = string
  default     = "http://localhost:4566"
}

# Names of the Lambda functions that implement each pipeline state. The
# functions themselves (code, role, deploy) are provisioned and owned by the
# `codereview-lambda` repository — this repo only needs the name to build the
# ARN and reference it in the State Machine and IAM policies.
variable "route_model_lambda_name" {
  description = "Name of the Lambda function implementing the RouteModel state (owned by codereview-lambda)."
  type        = string
  default     = "codereview-route-model"
}

variable "retrieve_context_lambda_name" {
  description = "Name of the Lambda function implementing the RetrieveContext state (owned by codereview-lambda)."
  type        = string
  default     = "codereview-retrieve-context"
}

variable "invoke_llm_lambda_name" {
  description = "Name of the Lambda function implementing the InvokeLLM state (owned by codereview-lambda)."
  type        = string
  default     = "codereview-invoke-llm"
}

variable "post_comment_lambda_name" {
  description = "Name of the Lambda function implementing the PostComment state (owned by codereview-lambda)."
  type        = string
  default     = "codereview-post-comment"
}
