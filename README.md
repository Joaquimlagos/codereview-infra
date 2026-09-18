# codereview-infra

Infrastructure as code (EventBridge + Step Functions) for the AI PR review pipeline, with LocalStack support for free local execution.

This repository is the **glue** between the AWS services in the pipeline. It's part of a portfolio project split into 3 independent repositories:

- **`codereview-app`** — GitHub Actions that fires the PR event.
- **`codereview-infra`** (this repo) — EventBridge, Step Functions and IAM.
- **`codereview-lambda`** — the Lambda functions themselves: code, IAM roles, and deploy (harness, RAG, routing to the LLM via 9router, calling Gemini, posting the comment back to the PR).

**Ownership boundary**: this repo never provisions Lambda functions. It only references them by ARN, built from an agreed-upon function name (see [`lambda_arns.tf`](lambda_arns.tf)) — the functions themselves are created and deployed entirely by `codereview-lambda`. This repo's only responsibility is standing up the AWS glue: EventBridge, Step Functions, S3, and the IAM wiring between them.

## Current stage: infra skeleton

At this stage, EventBridge, Step Functions and IAM are configured and can be validated end-to-end once the 4 Lambda functions exist somewhere reachable by the same AWS account/LocalStack instance (see "Testing before `codereview-lambda` exists" below for a temporary workaround). There is no business logic, RAG, or real LLM call in this repository — that all lives in `codereview-lambda`.

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

- **Claim check via S3**: the `<project_name>-pr-diffs` bucket holds the full PR diff. EventBridge and Step Functions only carry lightweight metadata (PR number, repository, `needsRag` flag) and the object's **key** in S3 — never the full diff payload.
- **One Lambda per state**: `RouteModel`, `RetrieveContext`, `InvokeLLM` and `PostComment` are separate functions, each with its own dedicated IAM role, so scalability and concurrency can be tuned independently. They are built, deployed and owned by `codereview-lambda`; this repo only references their ARNs.
- **State Machine (ASL)**: defined in [`statemachine/definition.asl.json.tpl`](statemachine/definition.asl.json.tpl) and provisioned via `templatefile()` in [`stepfunctions.tf`](stepfunctions.tf).
- **Cross-repo reference without state coupling**: [`lambda_arns.tf`](lambda_arns.tf) builds each Lambda ARN from `arn:aws:lambda:<region>:<account_id>:function:<name>` using `data "aws_caller_identity"` + a `variable` per function name. No `terraform_remote_state`, no apply-ordering dependency between the two repos — just an agreed-upon naming convention.

## Repository structure

```
.
├── provider.tf              # AWS provider pointed at LocalStack
├── variables.tf / outputs.tf
├── lambda_arns.tf           # Lambda ARNs built by naming convention (owned by codereview-lambda)
├── s3.tf                    # Claim-check bucket for PR diffs
├── eventbridge.tf           # Event bus + rule + IAM to trigger the State Machine
├── stepfunctions.tf         # State Machine + IAM to invoke the Lambdas
├── statemachine/
│   └── definition.asl.json.tpl
└── scripts/test-event.json  # Manual test event for EventBridge
```

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [LocalStack](https://docs.localstack.cloud/getting-started/installation/) (`pip install localstack` or via Docker)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (used with `--endpoint-url` pointed at LocalStack)

## Running locally

### 1. Start LocalStack

```bash
localstack start -d
```

Check it's up:

```bash
localstack status services
```

### 2. Apply the infra with Terraform

```bash
terraform init
terraform apply
```

The provider is already configured in [`provider.tf`](provider.tf) to talk directly to `http://localhost:4566` with fake credentials (`test`/`test`), so no additional wrapper is needed.

At the end, note the outputs (especially the State Machine ARN):

```bash
terraform output
```

### 3. Set fake credentials for the AWS CLI

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
```

### 4. Testing before `codereview-lambda` exists

The State Machine references Lambda ARNs by name (`codereview-route-model`, `codereview-retrieve-context`, `codereview-invoke-llm`, `codereview-post-comment` by default — see `variables.tf`). Until `codereview-lambda` deploys the real functions with those names, an execution will fail with `Lambda.ResourceNotFoundException`.

To validate the EventBridge → Step Functions → IAM wiring on its own against LocalStack, create throwaway placeholder functions with matching names, e.g.:

```bash
for fn in codereview-route-model codereview-retrieve-context codereview-invoke-llm codereview-post-comment; do
  echo 'def handler(event, context): return {"stub": True}' > /tmp/handler.py
  (cd /tmp && zip -q placeholder.zip handler.py)
  aws lambda create-function \
    --endpoint-url http://localhost:4566 \
    --function-name "$fn" \
    --runtime python3.12 \
    --handler handler.handler \
    --zip-file fileb:///tmp/placeholder.zip \
    --role arn:aws:iam::000000000000:role/placeholder
done
```

This is a manual, throwaway verification step — not part of this repo's Terraform, and not meant to be maintained here.

### 5. Fire a manual test event

[`scripts/test-event.json`](scripts/test-event.json) simulates the event `codereview-app` would publish after a PR is opened:

```bash
aws events put-events \
  --endpoint-url http://localhost:4566 \
  --entries file://scripts/test-event.json
```

### 6. Validate the end-to-end execution

List executions triggered by the EventBridge rule:

```bash
aws stepfunctions list-executions \
  --endpoint-url http://localhost:4566 \
  --state-machine-arn "$(terraform output -raw state_machine_arn)"
```

Grab the returned `executionArn` and inspect its history:

```bash
aws stepfunctions get-execution-history \
  --endpoint-url http://localhost:4566 \
  --execution-arn <executionArn>
```

**Acceptance criteria**: the execution should complete successfully (`ExecutionSucceeded`), going through `RouteModel` → `NeedsRag` → `RetrieveContext` (since `needsRag: true` in the test event) → `InvokeLLM` → `PostComment`.

To test the no-RAG path, edit `scripts/test-event.json`, change `"needsRag": true` to `"needsRag": false`, and fire the event again — the execution should skip straight from `RouteModel` to `InvokeLLM`.

### 7. Tear down

```bash
terraform destroy
```

Since everything runs on LocalStack, there is no real AWS cost at any stage.
