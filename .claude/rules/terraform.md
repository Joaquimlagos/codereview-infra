---
paths: ["**/*.tf", "**/*.tfvars"]
---

# Terraform rules for codereview-infra

These rules apply whenever Terraform files (`.tf`, `.tfvars`) are created or edited in this repository.

## Formatting

- Run `terraform fmt -recursive` before considering any Terraform change done, and before any commit that touches `.tf`/`.tfvars` files.
- Never leave manually-aligned `=` signs or inconsistent indentation — let `terraform fmt` own formatting.

## Naming

- `snake_case` for all resource names, variable names, output names, and local names.
- Names must be descriptive, not abbreviated in obscure ways (`route_model_lambda`, not `rml`). Short, well-known AWS abbreviations (e.g. `arn`, `iam`, `sfn`) are fine.
- Resource labels (the second argument in `resource "type" "label"`) should describe the role in the pipeline, not repeat the resource type (`resource "aws_lambda_function" "route_model"`, not `resource "aws_lambda_function" "lambda"`).
- Prefix physical resource names (the `name`/`bucket`/`function_name` attribute) with `var.project_name` so resources are identifiable across environments.

## Module organization

- Organize by responsibility, never by dumping everything into one giant `main.tf`. Each AWS service/concern gets its own file or module: EventBridge (`eventbridge.tf`), Step Functions (`stepfunctions.tf`), S3 (`s3.tf`), Lambda ARN references (`lambda_arns.tf`), IAM roles/policies co-located with the resource that owns them.
- Reusable, structurally-identical resources belong in a shared module instead of being copy-pasted per instance.
- Root-level files stay thin: they wire up modules and resources, they don't contain implementation details that belong in a module.

## Ownership boundary: no Lambda provisioning in this repo

- This repository never provisions `aws_lambda_function` resources, Lambda IAM roles, or Lambda source code (no `.py`/`.js`/etc. handler files). Lambda functions are owned, built and deployed entirely by the `codereview-lambda` repository.
- This repo only reads Lambda ARNs from SSM Parameter Store, published by `codereview-lambda` after its own deploy at `/${var.project_name}/lambda/<state>/arn` (see `lambda_arns.tf`). Never use `terraform_remote_state` or any other shared-state-file coupling to fetch these ARNs.
- `codereview-lambda` must be deployed before this repo — the SSM lookup is a real apply-ordering dependency, and that's intentional and documented (in `lambda_arns.tf` and `README.md`), not something to design around. `var.lambda_arns_override` exists solely to unblock local `plan`/`apply` before `codereview-lambda` has published its parameters — never remove the SSM lookup path in favor of a permanent override.
- If a task seems to require adding a Lambda resource or handler code here, stop and flag it — that almost certainly belongs in `codereview-lambda` instead.

## Versioning

- `versions.tf` must always pin `required_version` for Terraform and `required_providers` with explicit version constraints (e.g. `~> 5.0`) for every provider in use. Never leave a provider unconstrained.
- Commit `.terraform.lock.hcl` — it is not a build artifact, it guarantees reproducible provider selection.

## Secrets and environment-specific values

- Never hardcode sensitive values or environment-specific values (account IDs, ARNs, endpoints, tokens) directly in `.tf` files. Use `variable` blocks with sane defaults for the default environment, overridden via `.tfvars` for other environments.
- Any `.tfvars` file that could contain real secrets or environment-specific values must never be committed — confirm it is covered by `.gitignore` (`*.tfvars`, `*.tfvars.json`) before adding new ones. Only commit an example file (`*.tfvars.example`) with placeholder values if one is needed.
- Mark sensitive variables with `sensitive = true`.

## Outputs

- Every resource that another repository (`codereview-app`, `codereview-lambda`) or a human operator will need to reference must have an explicit output in `outputs.tf`, with a `description`. Don't make consumers dig through `.tf` source to find an ARN or bucket name.

## Tags

- Every taggable resource gets a consistent set of tags: `Project`, `Environment`, `ManagedBy` (set to `"terraform"`). Prefer a shared `local.common_tags` merged into each resource's `tags` argument over repeating the same map everywhere.

## IAM

- Always least privilege. Never use `"*"` in an IAM policy `Action` or `Resource` field.
- Each Lambda/component gets its own dedicated IAM role — never share a role across unrelated resources.
- Scope `Resource` to specific ARNs (e.g. the exact Lambda ARNs a Step Functions role is allowed to invoke), not to a service-wide wildcard.

## for_each vs. count

- Prefer `for_each` over `count` when creating multiple similar resources, to avoid state-reordering issues when an item is added/removed from the middle of a list. Only use `count` for simple 0/1 conditional resource creation.

## Change review

- Always run `terraform plan` and show the diff before applying any change. Never run `terraform apply` (or suggest running it) without first reviewing a `plan` with the user.
