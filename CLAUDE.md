# codereview-infra

Infrastructure as code (Terraform) for the AI PR review pipeline. Portfolio project split into 3 independent repositories:

- **`codereview-app`** — GitHub Actions that fires the PR event.
- **`codereview-infra`** (this repo) — EventBridge, Step Functions and IAM.
- **`codereview-lambda`** — the Lambda functions themselves: code, IAM roles, deploy (harness, RAG, routing to the LLM via 9router, calling Gemini, posting the comment back to the PR).

**Ownership boundary — read this before touching Lambda-related code**: this repository never provisions `aws_lambda_function` resources, Lambda IAM roles, or Lambda source code. Those belong entirely to `codereview-lambda`. This repo only references Lambda ARNs, built from an agreed-upon naming convention (see [`lambda_arns.tf`](lambda_arns.tf): `arn:aws:lambda:<region>:<account_id>:function:<name>` via `data "aws_caller_identity"` + a `variable` per function name). If a change seems to require adding a `.py` file or an `aws_lambda_function` resource here, stop and reconsider — that logic belongs in `codereview-lambda`.

## Stack

- **IaC**: Terraform
- **Local execution**: LocalStack — provider configured in [`provider.tf`](provider.tf) with `endpoints {}` pointed at `http://localhost:4566` and fake credentials, no extra wrapper needed (`tflocal` is not required)
- **Target cloud**: AWS

## Pipeline architecture

```
GitHub Actions (codereview-app)
  → EventBridge (rule "PRReviewRequested")
  → Step Functions: RouteModel → Choice(needsRag) → [RetrieveContext] → InvokeLLM → PostComment
```

- **Claim check via S3**: the full PR diff lives in the `<project_name>-pr-diffs` bucket. EventBridge and Step Functions only carry lightweight metadata + the object's key in S3 — never the full payload.
- **One Lambda per state**: each state of the State Machine (`RouteModel`, `RetrieveContext`, `InvokeLLM`, `PostComment`) is a separate function owned by `codereview-lambda`, not a single function with internal handlers — this keeps IAM, concurrency and scalability independent per state.
- **State Machine in ASL**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()`.

## Current stage

EventBridge, Step Functions and IAM are wired up and reference Lambda ARNs by naming convention. End-to-end validation against LocalStack requires the 4 named functions to actually exist (deployed by `codereview-lambda`, or temporary throwaway placeholders — see [`README.md`](README.md) for a manual workaround). No business logic lives in this repository at any stage, dummy or otherwise.

## Working conventions

- Every taggable/referenceable resource needed by another repo gets an explicit output in `outputs.tf`, with a `description`.
- Each IAM role is dedicated to a single component (state machine, EventBridge rule) with least-privilege policies — never a wildcard `Action` or `Resource`, never a shared role across unrelated resources.
- Secrets (GitHub tokens, AI API keys) never get hardcoded — use Terraform variables marked `sensitive`, and a secrets manager (e.g. AWS Secrets Manager) in production. At this stage there are no real secrets yet.
- Resource naming uses the `var.project_name` prefix (default `codereview`) to make each resource's role in the pipeline clear (e.g. `codereview-pr-review` for the state machine).
- Differences between environments (local/LocalStack vs. real AWS) belong in `*.tfvars`, never duplicated across modules or resources.
- Always validate against LocalStack before even considering applying against real AWS.
- `.terraform.lock.hcl` is committed; state (`terraform.tfstate`) and `.terraform/` are not (see [`.gitignore`](.gitignore)).
- See [`.claude/rules/terraform.md`](.claude/rules/terraform.md) for the full Terraform style/organization ruleset, and [`.claude/rules/english-only.md`](.claude/rules/english-only.md) — all project content (code, comments, docs, commits) is English-only, regardless of the conversation language.
