# codereview-infra

Infrastructure as code (EventBridge + Step Functions) for the AI PR review pipeline, deployed directly against AWS.

This repository is the **glue** between the AWS services in the pipeline. It's part of a portfolio project split into 3 independent repositories:

- **`codereview-app`** — GitHub Actions that fires the PR event.
- **`codereview-infra`** (this repo) — EventBridge, Step Functions and IAM.
- **`codereview-lambda`** — the Lambda functions themselves: code, IAM roles, and deploy (harness, RAG, routing to the LLM via 9router, calling Gemini, posting the comment back to the PR).

**Ownership boundary**: this repo never provisions Lambda functions. It only reads their ARNs from SSM Parameter Store (see [`lambda_arns.tf`](lambda_arns.tf) and "Contract with `codereview-lambda`" below) — the functions themselves are created and deployed entirely by `codereview-lambda`. This repo's only responsibility is standing up the AWS glue: EventBridge, Step Functions, S3, and the IAM wiring between them.

## Current stage: infra skeleton

At this stage, EventBridge, Step Functions and IAM are configured and can be validated end-to-end once the 4 Lambda functions exist and have published their ARNs to SSM (see "Testing before `codereview-lambda` exists" below for a way to unblock local `plan`/`apply` before that). There is no business logic, RAG, or real LLM call in this repository — that all lives in `codereview-lambda`.

## Contract with `codereview-lambda`

After deploying each Lambda function, `codereview-lambda` must publish its ARN as a `String` SSM parameter at a predictable path:

```
/${var.project_name}/lambda/route-model/arn
/${var.project_name}/lambda/retrieve-context/arn
/${var.project_name}/lambda/invoke-llm/arn
/${var.project_name}/lambda/post-comment/arn
```

With the default `project_name = "codereview"`, that's e.g. `/codereview/lambda/route-model/arn`. This repo reads those parameters in [`lambda_arns.tf`](lambda_arns.tf) via `data "aws_ssm_parameter"` — no `terraform_remote_state` (no shared state file between the two repos), but `terraform plan`/`apply` here will fail with a "parameter not found" error if those parameters don't exist yet. Use `var.lambda_arns_override` (see "Testing before `codereview-lambda` exists" below) to bypass this locally.

The reverse also exists: this repo owns three Secrets Manager secrets and the PR diffs bucket (see [`secrets.tf`](secrets.tf) and [`s3.tf`](s3.tf)), and publishes their identifiers to SSM for `codereview-lambda` to consume:

| Resource | SSM parameter | Consumed by |
| --- | --- | --- |
| Secret `codereview/typesafe-api-key` | `/codereview/secrets/typesafe-api-key-arn` | RouteModel Lambda |
| Secret `codereview/gemini-api-key` | `/codereview/secrets/gemini-api-key-arn` | InvokeLLM Lambda |
| Secret `codereview/github-token` | `/codereview/secrets/github-token-arn` | PostComment Lambda |
| S3 bucket `codereview-pr-diffs` (name, not ARN) | `/codereview/s3/pr-diffs-bucket-name` | All Lambdas that read/write diffs — populates `DIFF_BUCKET` |

All three secrets are created empty — this repo never sets or reads their values, and never grants any IAM permission to read them. `codereview-lambda` is responsible for reading each ARN from SSM and granting `secretsmanager:GetSecretValue` on it only to the execution role of the one function that needs it. After `terraform apply`, set the real values manually:

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -json secret_arns | jq -r .typesafe_api_key)" \
  --secret-string "<real-value>"
```

### Bootstrap order

Because this repo both *produces* SSM parameters (secrets, bucket name) that `codereview-lambda` needs, and *consumes* SSM parameters (Lambda ARNs) that `codereview-lambda` produces, a single unordered `terraform apply` on both sides can't work — the correct sequence is:

1. **`codereview-infra`, targeted apply** — create the secrets, the S3 bucket, the event bus, and the GitHub Actions OIDC role (and their SSM parameters), so both `codereview-lambda` and `codereview-app` have what they need to run:
   ```bash
   terraform apply \
     -target=aws_secretsmanager_secret.this \
     -target=aws_ssm_parameter.secret_arn \
     -target=aws_s3_bucket.pr_diffs \
     -target=aws_ssm_parameter.pr_diffs_bucket_name \
     -target=aws_cloudwatch_event_bus.pr_review \
     -target=aws_iam_role.github_actions_pr_review
   ```
2. **`codereview-lambda` apply** — reads the secret ARNs and bucket name from SSM, deploys the 4 Lambda functions, and publishes their ARNs to SSM.
3. **`codereview-infra`, full apply** — `terraform apply` with no `-target`, now that the Lambda ARN parameters exist; this provisions the EventBridge rule, Step Functions, and the remaining IAM wiring between them.

Step 1 only needs to run once (or again when a secret/bucket/OIDC definition changes); after that, day-to-day changes to either repo can be applied independently as long as step 1's resources still exist.

## GitHub Actions authentication (OIDC)

[`oidc.tf`](oidc.tf) sets up keyless auth for `codereview-app`'s CI workflow: an `aws_iam_openid_connect_provider` trusting `token.actions.githubusercontent.com` (thumbprint fetched live via `data "tls_certificate"`, never hardcoded), and a role (`github_actions_pr_review`) that only that specific repo (`var.github_owner`/`var.github_repo`, any branch) can assume, scoped to `events:PutEvents` on this repo's custom event bus and `s3:PutObject` on the diffs bucket — nothing else.

Set `github_owner` (no default — it's account-specific) and, if not using the default, `github_repo` before applying:

```bash
terraform apply -var="github_owner=your-github-username-or-org"
```

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

- **Claim check via S3**: the `<project_name>-pr-diffs` bucket holds the full PR diff. EventBridge and Step Functions only carry lightweight metadata (PR number, repository) and the object's **key** in S3 — never the full diff payload.
- **One Lambda per state**: `RouteModel`, `RetrieveContext`, `InvokeLLM` and `PostComment` are separate functions, each with its own dedicated IAM role, so scalability and concurrency can be tuned independently. They are built, deployed and owned by `codereview-lambda`; this repo only references their ARNs.
- **State Machine (ASL)**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()` in [`stepfunctions.tf`](stepfunctions.tf).
- **Cross-repo reference without state coupling**: [`lambda_arns.tf`](lambda_arns.tf) reads each Lambda ARN from SSM Parameter Store, published there by `codereview-lambda` after its own deploy — see "Contract with `codereview-lambda`" above.
- **Secrets**: [`secrets.tf`](secrets.tf) creates two empty Secrets Manager secrets (`typesafe-api-key`, `gemini-api-key`) and publishes their ARNs to SSM the same way, so `codereview-lambda` never hardcodes a secret ARN. No read permission is granted here — see the table above.

## Repository structure

```
.
├── provider.tf              # AWS provider (credentials from the environment)
├── variables.tf / outputs.tf
├── lambda_arns.tf           # Lambda ARNs read from SSM Parameter Store (owned by codereview-lambda)
├── secrets.tf               # Empty Secrets Manager secrets + their ARNs published to SSM
├── locals.tf                # Shared local.common_tags (Project/Environment/ManagedBy)
├── s3.tf                    # Claim-check bucket (30-day expiration) + its name published to SSM
├── eventbridge.tf           # Event bus + rule + IAM to trigger the State Machine
├── stepfunctions.tf         # State Machine + IAM to invoke the Lambdas
├── oidc.tf                  # GitHub Actions OIDC provider + role for codereview-app's CI
├── statemachine/
│   └── definition.asl.json.tpl
└── scripts/test-event.json  # Manual test event for EventBridge
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
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

This repo provisions real AWS resources — nothing here is free indefinitely (though everything fits comfortably in the AWS free tier for occasional testing). Destroy what you don't need running:

```bash
terraform destroy
```

If you only want to tear down the pipeline wiring but keep the bootstrap resources (secrets, bucket, OIDC role) that `codereview-lambda`/`codereview-app` depend on, target the destroy instead of running it against the whole state.
