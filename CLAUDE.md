# codereview-infra

Infrastructure as code (Terraform) for the AI PR review pipeline. Portfolio project split into 3 independent repositories:

- **`codereview-app`** — GitHub Actions that fires the PR event.
- **`codereview-infra`** (this repo) — EventBridge, Step Functions and IAM.
- **`codereview-lambda`** — the Lambda functions themselves: code, IAM roles, deploy (harness, RAG, routing to the LLM via 9router, calling Gemini, posting the comment back to the PR).

**Ownership boundary — read this before touching Lambda-related code**: this repository never provisions `aws_lambda_function` resources, Lambda IAM roles, or Lambda source code. Those belong entirely to `codereview-lambda`. This repo only reads Lambda ARNs from SSM Parameter Store (see [`lambda_arns.tf`](lambda_arns.tf)), published by `codereview-lambda` after its own deploy at `/${var.project_name}/lambda/<state>/arn`. **Deploy order matters**: `codereview-lambda` must be applied before this repo, or the SSM lookups fail (`var.lambda_arns_override` bypasses this for local testing — see README). If a change seems to require adding a `.py` file or an `aws_lambda_function` resource here, stop and reconsider — that logic belongs in `codereview-lambda`.

## Stack

- **IaC**: Terraform
- **Cloud**: AWS — [`provider.tf`](provider.tf) takes credentials from the environment (local AWS profile, or the OIDC role in CI — see `oidc.tf`), never hardcoded

## Pipeline architecture

```
GitHub Actions (codereview-app)
  → EventBridge (rule "PRReviewRequested")
  → Step Functions: RouteModel → CheckNeedsContext (Choice) → [RetrieveContext] → InvokeLLM → PostComment
```

- **Claim check via S3**: the full PR diff lives in the `<project_name>-pr-diffs` bucket. EventBridge and Step Functions only carry lightweight metadata + the object's key in S3 — never the full payload.
- **One Lambda per state**: each state of the State Machine (`RouteModel`, `RetrieveContext`, `InvokeLLM`, `PostComment`) is a separate function owned by `codereview-lambda`, not a single function with internal handlers — this keeps IAM, concurrency and scalability independent per state.
- **State Machine in ASL**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()`.
- **Secrets**: [`secrets.tf`](secrets.tf) owns three empty Secrets Manager secrets (`typesafe-api-key`, `gemini-api-key`, `github-token`) consumed by `codereview-lambda`, and publishes their ARNs to SSM at `/${var.project_name}/secrets/<key>-arn`. This repo never sets a real secret value and never grants any read permission on them — `codereview-lambda` scopes `secretsmanager:GetSecretValue` to each function's own execution role for only the secret it needs (RouteModel → typesafe, InvokeLLM → gemini, PostComment → github-token).
- **GitHub Actions OIDC**: [`oidc.tf`](oidc.tf) trusts `token.actions.githubusercontent.com` (thumbprint fetched via `data "tls_certificate"`, never hardcoded) and lets only `codereview-app` (scoped by `var.github_owner`/`var.github_repo`) assume a role limited to `events:PutEvents` on this repo's event bus and `s3:PutObject` on the diffs bucket. Nothing else.

## Current stage

EventBridge, Step Functions and IAM are wired up and read Lambda ARNs from SSM Parameter Store. End-to-end validation against AWS requires the 4 functions to actually exist and have published their ARNs (deployed by `codereview-lambda`, or `var.lambda_arns_override` for a throwaway workaround — see [`README.md`](README.md)). No business logic lives in this repository at any stage, dummy or otherwise.

## Working conventions

- Every taggable/referenceable resource needed by another repo gets an explicit output in `outputs.tf`, with a `description`.
- Every taggable AWS resource gets `tags = local.common_tags` (see [`locals.tf`](locals.tf): `Project`, `Environment`, `ManagedBy`) — never a one-off tag map.
- Each IAM role is dedicated to a single component (state machine, EventBridge rule) with least-privilege policies — never a wildcard `Action` or `Resource`, never a shared role across unrelated resources.
- Secrets (GitHub tokens, AI API keys) never get hardcoded — use Terraform variables marked `sensitive`, and Secrets Manager for real values (see [`secrets.tf`](secrets.tf)). Real secret values are never set in Terraform code, ever — only empty/placeholder containers, populated manually after deploy.
- Resource naming uses the `var.project_name` prefix (default `codereview`) to make each resource's role in the pipeline clear (e.g. `codereview-pr-review` for the state machine).
- Differences between environments (dev vs. prod) belong in `*.tfvars`, never duplicated across modules or resources.
- `.terraform.lock.hcl` is committed; state (`terraform.tfstate`) and `.terraform/` are not (see [`.gitignore`](.gitignore)).
- See [`.claude/rules/terraform.md`](.claude/rules/terraform.md) for the full Terraform style/organization ruleset, and [`.claude/rules/english-only.md`](.claude/rules/english-only.md) — all project content (code, comments, docs, commits) is English-only, regardless of the conversation language.
