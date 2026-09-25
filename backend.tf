# Remote state lives in the same artifacts bucket this repo manages, under a
# prefix of its own (terraform-state/) kept apart from application data
# (prs/, index/). The prs/-only lifecycle rule in s3.tf never touches it, the
# codereview-app OIDC role can't write to it (oidc.tf scopes s3:PutObject to
# prs/ and index/ only), and bucket versioning keeps prior state versions
# recoverable.
#
# Backend blocks can't reference variables, so bucket/key/region are
# literal here. Because the bucket is itself created by this configuration,
# bootstrapping a fresh account has to start with local state: comment this
# block out, run the phase-1 targeted apply, then restore it and run
# `terraform init -migrate-state`.
#
# Locking uses S3-native lockfiles (use_lockfile, Terraform >= 1.10): a
# .tflock object is written next to the state key for the duration of each
# operation, so a second concurrent plan/apply fails fast instead of
# silently overwriting the state. No DynamoDB table needed.
terraform {
  backend "s3" {
    bucket       = "codereview-artifacts"
    key          = "terraform-state/codereview-infra.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
