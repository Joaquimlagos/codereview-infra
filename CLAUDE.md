# codereview-infra

Infrastructure as code (Terraform) for the AI PR review pipeline. Portfolio project split into 3 independent repositories:

- **`codereview-app`** — triggers: GitHub Actions that upload the PR diff, publish the review event and build the method-level RAG index.
- **`codereview-infra`** (this repo) — orchestrates: EventBridge, Step Functions, the artifacts bucket, Secrets Manager secrets and the GitHub OIDC role.
- **`codereview-lambda`** — executes: the four Lambda functions, their IAM roles and deploy (complexity classification via the Jev decision engine, method-level RAG context, LLM calls with Groq/Cerebras/Gemini fallback, posting the review back to the PR).

**Ownership boundary — read this before touching Lambda-related code**: this repository never provisions `aws_lambda_function` resources, Lambda IAM roles, or Lambda source code. Those belong entirely to `codereview-lambda`. This repo only reads Lambda ARNs from SSM Parameter Store (see [`lambda_arns.tf`](lambda_arns.tf)), published by `codereview-lambda` after its own deploy at `/${var.project_name}/lambda/<state>/arn`. **Deploy order matters**: on a fresh account it runs in four phases — this repo's secrets and bucket (targeted apply), the secret values, `codereview-lambda`, then this repo's full apply; without the Lambda ARN parameters a full apply here fails its SSM lookups (`var.lambda_arns_override` bypasses this for local testing). The commands are in README's "Bootstrap order". If a change seems to require adding a `.py` file or an `aws_lambda_function` resource here, stop and reconsider — that logic belongs in `codereview-lambda`.

## Stack

- **IaC**: Terraform
- **Cloud**: AWS — [`provider.tf`](provider.tf) takes credentials from the environment (a local AWS profile; this repo's CI has no AWS access), never hardcoded. The OIDC role in `oidc.tf` is for `codereview-app`'s workflows, not for this repo

## Pipeline architecture

```
GitHub Actions (codereview-app)
  → EventBridge (rule "PRReviewRequested")
  → Step Functions: RouteModel → CheckNeedsContext (Choice) → [RetrieveContext] → InvokeLLM → PostComment
```

- **Claim check + RAG index + Terraform state via S3**: the `<project_name>-artifacts` bucket holds three unrelated kinds of data split by prefix, not by bucket — `prs/{pr}/{sha}.diff` (PR diff claim check, expires after 30 days), `index/develop/index.json` (RAG embeddings index, never expires), and `terraform-state/` (this repo's remote state, see [`backend.tf`](backend.tf); locked via `use_lockfile`). The bucket is versioned and has no `force_destroy`, so a `terraform destroy` can never silently delete the state it runs from. EventBridge and Step Functions only carry lightweight metadata + the diff's key in S3 — never the full payload.
- **One Lambda per state**: each state of the State Machine (`RouteModel`, `RetrieveContext`, `InvokeLLM`, `PostComment`) is a separate function owned by `codereview-lambda`, not a single function with internal handlers — this keeps IAM, concurrency and scalability independent per state.
- **State Machine in ASL**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()`.
- **Secrets**: [`secrets.tf`](secrets.tf) owns five empty Secrets Manager secrets (`typesafe-api-key`, `gemini-api-key`, `groq-api-key`, `cerebras-api-key`, `github-app-private-key`) consumed by `codereview-lambda`, and publishes their ARNs to SSM at `/${var.project_name}/secrets/<key>-arn`. This repo never sets a real secret value and never grants any read permission on them — `codereview-lambda` scopes `secretsmanager:GetSecretValue` to each function's own execution role for only the secret it needs (RouteModel → typesafe, InvokeLLM → gemini + groq + cerebras, PostComment → github-app-private-key). The old `github-token` PAT secret was removed once the GitHub App was validated in production.
- **GitHub Actions OIDC**: [`oidc.tf`](oidc.tf) trusts `token.actions.githubusercontent.com` (thumbprint fetched via `data "tls_certificate"`, never hardcoded) and lets only `codereview-app` assume a role — the `sub` condition pins owner and repo by name **and** immutable numeric ID (`repo:<owner>@<owner_id>/<repo>@<repo_id>:*`, the format GitHub actually sends; never wildcard the owner/repo part) — limited to `events:PutEvents` on this repo's event bus and `s3:PutObject` on the artifacts bucket's `prs/*` and `index/*` prefixes only. Nothing else — in particular never the whole bucket, since that would let CI overwrite `terraform-state/`.

## Current stage

Deployed and running end to end: the four Lambdas from `codereview-lambda` exist and publish their ARNs to SSM, and pull requests on `codereview-app` are reviewed through this state machine. `var.lambda_arns_override` is only for testing the wiring in isolation (see [`README.md`](README.md)). No business logic lives in this repository, dummy or otherwise.

## Working conventions

- Every taggable/referenceable resource needed by another repo gets an explicit output in `outputs.tf`, with a `description`.
- Every taggable AWS resource gets `tags = local.common_tags` (see [`locals.tf`](locals.tf): `Project`, `Environment`, `ManagedBy`) — never a one-off tag map.
- Each IAM role is dedicated to a single component (state machine, EventBridge rule) with least-privilege policies — never a wildcard `Action` or `Resource`, never a shared role across unrelated resources.
- Secrets (GitHub tokens, AI API keys) never get hardcoded — use Terraform variables marked `sensitive`, and Secrets Manager for real values (see [`secrets.tf`](secrets.tf)). Real secret values are never set in Terraform code, ever — only empty/placeholder containers, populated manually after deploy.
- Resource naming uses the `var.project_name` prefix (default `codereview`) to make each resource's role in the pipeline clear (e.g. `codereview-pr-review` for the state machine).
- Differences between environments (dev vs. prod) belong in `*.tfvars`, never duplicated across modules or resources.
- `.terraform.lock.hcl` is committed; state (`terraform.tfstate`) and `.terraform/` are not (see [`.gitignore`](.gitignore)).
- CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `terraform fmt -check -recursive`, `terraform init -backend=false` and `terraform validate` on pushes to `main` and on every pull request. It is static by design: no AWS credentials, no secrets, `permissions: contents: read` only, and `-backend=false` so it never touches the remote state. Never add `plan`/`apply`, credentials, or an `init` that uses the backend to it. Everything must pass without `terraform.tfvars` (gitignored), so a new variable without a default must not break `validate`. The workflow's pinned `terraform_version` must satisfy `required_version` in `versions.tf`; keep them in sync.
- See [`.claude/rules/terraform.md`](.claude/rules/terraform.md) for the full Terraform style/organization ruleset, and [`.claude/rules/english-only.md`](.claude/rules/english-only.md) — all project content (code, comments, docs, commits) is English-only, regardless of the conversation language.
