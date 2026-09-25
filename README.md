# codereview-infra

Infrastructure as code (EventBridge + Step Functions) for the AI PR review pipeline, deployed directly against AWS.

This repository is the **glue** between the AWS services in the pipeline. It's part of a portfolio project split into 3 independent repositories:

- **`codereview-app`** — GitHub Actions that fires the PR event.
- **`codereview-infra`** (this repo) — EventBridge, Step Functions and IAM.
- **`codereview-lambda`** — the Lambda functions themselves: code, IAM roles, and deploy (harness, RAG, routing to the LLM via 9router, calling Gemini, posting the comment back to the PR).

**Ownership boundary**: this repo never provisions Lambda functions. It only reads their ARNs from SSM Parameter Store (see [`lambda_arns.tf`](lambda_arns.tf) and "Contract with `codereview-lambda`" below) — the functions themselves are created and deployed entirely by `codereview-lambda`. This repo's only responsibility is standing up the AWS glue: EventBridge, Step Functions, S3, and the IAM wiring between them. There is no business logic, RAG, or LLM call in this repository.

## Contract with `codereview-lambda`

After deploying each Lambda function, `codereview-lambda` must publish its ARN as a `String` SSM parameter at a predictable path:

```
/${var.project_name}/lambda/route-model/arn
/${var.project_name}/lambda/retrieve-context/arn
/${var.project_name}/lambda/invoke-llm/arn
/${var.project_name}/lambda/post-comment/arn
```

With the default `project_name = "codereview"`, that's e.g. `/codereview/lambda/route-model/arn`. This repo reads those parameters in [`lambda_arns.tf`](lambda_arns.tf) via `data "aws_ssm_parameter"` — no `terraform_remote_state` (no shared state file between the two repos), but `terraform plan`/`apply` here will fail with a "parameter not found" error if those parameters don't exist yet. Use `var.lambda_arns_override` (see "Testing before `codereview-lambda` exists" below) to bypass this locally.

The reverse also exists: this repo owns four Secrets Manager secrets and the shared artifacts bucket (see [`secrets.tf`](secrets.tf) and [`s3.tf`](s3.tf)), and publishes their identifiers to SSM for `codereview-lambda` to consume:

| Resource | SSM parameter | Consumed by |
| --- | --- | --- |
| Secret `codereview/typesafe-api-key` | `/codereview/secrets/typesafe-api-key-arn` | RouteModel Lambda |
| Secret `codereview/gemini-api-key` | `/codereview/secrets/gemini-api-key-arn` | InvokeLLM Lambda |
| Secret `codereview/groq-api-key` | `/codereview/secrets/groq-api-key-arn` | InvokeLLM Lambda (fallback LLM provider) |
| Secret `codereview/github-app-private-key` | `/codereview/secrets/github-app-private-key-arn` | PostComment Lambda |
| S3 bucket `codereview-artifacts` (name, not ARN) | `/codereview/s3/artifacts-bucket-name` | Lambdas/workflows that read/write diffs or the RAG index |

All four secrets are created empty — this repo never sets or reads their values, and never grants any IAM permission to read them. `codereview-lambda` is responsible for reading each ARN from SSM and granting `secretsmanager:GetSecretValue` on it only to the execution role of the one function that needs it. After `terraform apply`, set the real values manually:

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -json secret_arns | jq -r .typesafe_api_key)" \
  --secret-string "<real-value>"
```

### Bucket layout

`codereview-artifacts` is one bucket serving three unrelated kinds of data, split by prefix instead of by bucket:

| Prefix | Contents | Written by | Read by | Expiration |
| --- | --- | --- | --- | --- |
| `prs/{pr}/{sha}.diff` | PR diff claim check | `codereview-app` CI | Whichever `codereview-lambda` state(s) need the diff | 30 days |
| `index/develop/index.json` | RAG embeddings index | `codereview-app` indexing workflow | RetrieveContext | Never |
| `terraform-state/` | This repo's Terraform state (see [`backend.tf`](backend.tf)) | Terraform, run by a developer | Terraform | Never |

One bucket, not several, because the things that need to differ between prefixes — lifecycle and IAM scoping — are both expressible per-prefix in AWS:
- **Lifecycle**: the rule in [`s3.tf`](s3.tf) filters on `prefix = "prs/"`, so `index/` and `terraform-state/` are never expired.
- **IAM**: the `codereview-app` OIDC role's `s3:PutObject` in [`oidc.tf`](oidc.tf) lists `prs/*` and `index/*` explicitly, so CI can never write to `terraform-state/`. It must never be widened back to the whole bucket (`.../*`).

The bucket is versioned, so any object — the Terraform state in particular — can be restored to a previous version after a bad write. A second bucket would only add a second name, a second SSM parameter, and a second thing to keep in sync, with no isolation the prefix split doesn't already give.

### Bootstrap order

Because this repo both *produces* SSM parameters (secrets, bucket name) that `codereview-lambda` needs, and *consumes* SSM parameters (Lambda ARNs) that `codereview-lambda` produces, a single unordered `terraform apply` on both sides can't work. The real sequence runs in phases:

1. **`codereview-infra`, targeted apply: secrets + bucket.** Create only the secrets, the artifacts bucket, and the SSM parameters that publish their identifiers. Nothing else can be applied yet: Step Functions and its IAM policy need Lambda ARNs that don't exist until phase 3.
   ```bash
   terraform apply \
     -target='aws_secretsmanager_secret.this["typesafe_api_key"]' \
     -target='aws_secretsmanager_secret.this["gemini_api_key"]' \
     -target='aws_secretsmanager_secret.this["groq_api_key"]' \
     -target='aws_secretsmanager_secret.this["github_app_private_key"]' \
     -target='aws_ssm_parameter.secret_arn["typesafe_api_key"]' \
     -target='aws_ssm_parameter.secret_arn["gemini_api_key"]' \
     -target='aws_ssm_parameter.secret_arn["groq_api_key"]' \
     -target='aws_ssm_parameter.secret_arn["github_app_private_key"]' \
     -target=aws_s3_bucket.artifacts \
     -target=aws_ssm_parameter.artifacts_bucket_name
   ```
   On a fresh account this phase has to run with **local** state, because the S3 backend ([`backend.tf`](backend.tf)) stores state in the bucket this phase creates. Comment out the `backend "s3"` block, apply, restore it, then run `terraform init -migrate-state` to move the state into `s3://codereview-artifacts/terraform-state/codereview-infra.tfstate`.
2. **Fill in the secret values.** The secrets are created empty; set each real value manually with `aws secretsmanager put-secret-value` (see above) or the console. Do this before phase 3 so the Lambdas can read their secrets.
3. **`codereview-lambda` apply.** Reads the secret ARNs and bucket name from SSM, deploys the 4 Lambda functions, and publishes their ARNs to SSM at `/codereview/lambda/<state>/arn`.
4. **`codereview-infra`, full apply.** Run `terraform apply` with no `-target`, now that the Lambda ARN parameters exist. This creates everything left: the EventBridge bus and rule, the Step Functions state machine and its IAM, the GitHub Actions OIDC provider and role, and the bucket's lifecycle rule. `codereview-app` can't trigger the pipeline until this phase is done, because its OIDC role doesn't exist before then.

Phases 1 and 2 only need to run once (or again when a secret/bucket definition changes). After phase 4, day-to-day changes to either repo can be applied independently.

## GitHub Actions authentication (OIDC)

[`oidc.tf`](oidc.tf) sets up keyless auth for `codereview-app`'s CI workflow: an `aws_iam_openid_connect_provider` trusting `token.actions.githubusercontent.com` (thumbprint fetched live via `data "tls_certificate"`, never hardcoded), and a role (`github_actions_pr_review`) that only that specific repo (any branch) can assume, scoped to `events:PutEvents` on this repo's custom event bus and `s3:PutObject` on the artifacts bucket's `prs/` and `index/` prefixes only (never `terraform-state/`) — nothing else.

### Why the trust policy pins numeric IDs

GitHub sends the OIDC `sub` claim with the immutable numeric IDs of the owner account and the repository, not just their names:

```
repo:my-org@12345678/codereview-app@987654321:ref:refs/heads/develop
```

The trust policy matches that exact shape — `repo:${github_owner}@${github_owner_id}/${github_repo}@${github_repo_id}:*` — with no wildcard on the owner or repo part. Names can change hands: if the repo is renamed, or deleted and recreated under the same name by another account, the name still matches but the ID doesn't, so that repo can't assume the role. The trailing `:*` only covers the ref/event suffix (branch, pull request, etc.).

A condition written against the name-only format (`repo:<owner>/<repo>:*`) never matches this claim, and `AssumeRoleWithWebIdentity` is denied.

### Setting the variables

Set these in `terraform.tfvars` (gitignored; see [`terraform.tfvars.example`](terraform.tfvars.example)):

| Variable | Default | Value |
| --- | --- | --- |
| `github_owner` | none | GitHub account/org name |
| `github_repo` | `codereview-app` | Repository name |
| `github_owner_id` | none | Numeric ID of the owner account |
| `github_repo_id` | none | Numeric ID of the repository |

Both IDs are digits only (the variables reject anything else). Two ways to get them:

- **GitHub API** (no auth needed for public data):
  ```bash
  curl -s https://api.github.com/users/<owner> | jq .id                  # github_owner_id
  curl -s https://api.github.com/repos/<owner>/codereview-app | jq .id   # github_repo_id
  ```
- **CloudTrail**: after a denied run of the `trigger-review` job, find the `AssumeRoleWithWebIdentity` event and read the `sub` value from it. Both IDs are in it, after the `@` signs.

Grab the role ARN for the `codereview-app` workflow:

```bash
terraform output -raw github_actions_pr_review_role_arn
```

In the `codereview-app` workflow YAML, use it with [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials):

```yaml
permissions:
  id-token: write   # required — without this, GitHub never issues the OIDC token, even if the AWS role is configured correctly
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::<account-id>:role/codereview-github-actions-pr-review
      aws-region: us-east-1
```

## Architecture

```
GitHub Actions (codereview-app)
        │  put-events (metadata + S3 key)
        ▼
   EventBridge (rule "PRReviewRequested")
        ▼
   Step Functions
        │
   ┌────┴────────────────────────────────────┐
   │ RouteModel                               │  Lambda (codereview-lambda)
   │   ▼                                       │
   │ Choice: needs RAG?                       │
   │   ├── yes → RetrieveContext ───────────┐ │
   │   └── no  ──────────────────────────────┤ │
   │                                          ▼ │
   │                                    InvokeLLM
   │                                          ▼
   │                                    PostComment
   └───────────────────────────────────────────┘
```

- **Claim check + RAG index via S3**: the `<project_name>-artifacts` bucket holds the full PR diff (`prs/` prefix) and the RAG embeddings index (`index/` prefix) — see "Bucket layout" above. EventBridge and Step Functions only carry lightweight metadata (PR number, repository) and the object's **key** in S3 — never the full diff payload.
- **One Lambda per state**: `RouteModel`, `RetrieveContext`, `InvokeLLM` and `PostComment` are separate functions, each with its own dedicated IAM role, so scalability and concurrency can be tuned independently. They are built, deployed and owned by `codereview-lambda`; this repo only references their ARNs.
- **State Machine (ASL)**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()` in [`stepfunctions.tf`](stepfunctions.tf).
- **Cross-repo reference without state coupling**: [`lambda_arns.tf`](lambda_arns.tf) reads each Lambda ARN from SSM Parameter Store, published there by `codereview-lambda` after its own deploy — see "Contract with `codereview-lambda`" above.
- **Secrets**: [`secrets.tf`](secrets.tf) creates four empty Secrets Manager secrets (`typesafe-api-key`, `gemini-api-key`, `groq-api-key`, `github-app-private-key`) and publishes their ARNs to SSM the same way, so `codereview-lambda` never hardcodes a secret ARN. No read permission is granted here — see the table above.

## Repository structure

```
.
├── backend.tf               # S3 remote state (terraform-state/ prefix of the artifacts bucket)
├── provider.tf              # AWS provider (credentials from the environment)
├── variables.tf / outputs.tf
├── lambda_arns.tf           # Lambda ARNs read from SSM Parameter Store (owned by codereview-lambda)
├── secrets.tf               # Empty Secrets Manager secrets + their ARNs published to SSM
├── locals.tf                # Shared local.common_tags (Project/Environment/ManagedBy)
├── s3.tf                    # Versioned artifacts bucket (prs/, index/, terraform-state/) + its name published to SSM
├── eventbridge.tf           # Event bus + rule + IAM to trigger the State Machine
├── stepfunctions.tf         # State Machine + IAM to invoke the Lambdas
├── oidc.tf                  # GitHub Actions OIDC provider + role for codereview-app's CI
├── terraform.tfvars.example # Template for the gitignored terraform.tfvars
├── statemachine/
│   └── definition.asl.json.tpl
└── scripts/test-event.json  # Manual test event for EventBridge
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.10 (the S3 backend uses `use_lockfile`)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with a real AWS profile that has permission to create the resources in this repo (`aws configure`, or an SSO profile — see `AWS_PROFILE`)

## Running against AWS

### 1. Configure credentials

```bash
export AWS_PROFILE=<your-profile>
export AWS_DEFAULT_REGION=us-east-1
```

The provider ([`provider.tf`](provider.tf)) reads credentials from the environment — no keys are ever hardcoded in this repo.

### 2. Apply the infra with Terraform

```bash
terraform init
terraform apply
```

At the end, note the outputs (especially the State Machine ARN):

```bash
terraform output
```

### 3. Testing before `codereview-lambda` exists

By default, `lambda_arns.tf` reads each Lambda ARN from SSM Parameter Store. Until `codereview-lambda` exists and publishes those parameters, `terraform plan`/`apply` will fail trying to read them.

To unblock `plan`/`apply` in isolation, set `var.lambda_arns_override` in a local `.tfvars` (already covered by `.gitignore` — never commit real ARNs here, only throwaway ones):

```hcl
# local.tfvars — not committed
lambda_arns_override = {
  route_model      = "arn:aws:lambda:us-east-1:<account-id>:function:fake-route-model"
  retrieve_context = "arn:aws:lambda:us-east-1:<account-id>:function:fake-retrieve-context"
  invoke_llm       = "arn:aws:lambda:us-east-1:<account-id>:function:fake-invoke-llm"
  post_comment     = "arn:aws:lambda:us-east-1:<account-id>:function:fake-post-comment"
}
```

```bash
terraform apply -var-file=local.tfvars
```

Any key present in `lambda_arns_override` skips the SSM lookup for that state entirely. Once `codereview-lambda` is deployed and publishing real parameters, drop this file and run `terraform apply` with no overrides — the ARNs will resolve from SSM.

Note: these fake ARNs let the State Machine and IAM policies provision successfully, but an actual **execution** will still fail with `Lambda.ResourceNotFoundException` since nothing is deployed at those ARNs. That's expected — this step validates the EventBridge → Step Functions → IAM wiring, not a full pipeline run. A full end-to-end execution (step 5 below) requires the real Lambdas from `codereview-lambda` to exist.

### 4. Fire a manual test event

[`scripts/test-event.json`](scripts/test-event.json) simulates the event `codereview-app` would publish after a PR is opened:

```bash
aws events put-events --entries file://scripts/test-event.json
```

### 5. Validate the end-to-end execution

List executions triggered by the EventBridge rule:

```bash
aws stepfunctions list-executions \
  --state-machine-arn "$(terraform output -raw state_machine_arn)"
```

Grab the returned `executionArn` and inspect its history:

```bash
aws stepfunctions get-execution-history --execution-arn <executionArn>
```

**Acceptance criteria**: the execution should complete successfully (`ExecutionSucceeded`), going through `RouteModel` → `CheckNeedsContext` → (`RetrieveContext` or straight to) `InvokeLLM` → `PostComment`. Whether `RetrieveContext` runs depends entirely on the `needsContext` field `RouteModel` itself returns (`$.routing.needsContext`) — that's `codereview-lambda`'s own routing logic, not something this repo or the test event controls.

### 6. Tear down

This repo provisions real AWS resources — nothing here is free indefinitely (though everything fits comfortably in the AWS free tier for occasional testing).

**Tearing down only the pipeline wiring** (EventBridge, Step Functions, OIDC) while keeping the bootstrap resources (secrets, bucket) that `codereview-lambda`/`codereview-app` depend on: use `terraform destroy` with `-target` on those resources. The bucket and the state stay untouched.

**Tearing down everything, including the bucket**, is deliberately not a single command. The bucket has no `force_destroy`, so `terraform destroy` fails on a non-empty bucket instead of silently deleting everything in it. And you can't simply empty the bucket first either: `terraform-state/` holds the very state `terraform destroy` needs. The order is:

1. **Move the state out of the bucket.** Comment out the `backend "s3"` block in [`backend.tf`](backend.tf) and run `terraform init -migrate-state`, which copies the state back to a local `terraform.tfstate`.
2. **Empty the bucket manually**: `prs/`, `index/`, and the now-stale `terraform-state/`. The bucket is versioned, so every object version and delete marker has to go, not just the current objects — `aws s3 rm --recursive` is not enough. The console's "Empty" button handles versions.
3. **Run `terraform destroy`** against the local state.
