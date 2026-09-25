# Authentication comes from the environment: a local AWS profile
# (AWS_PROFILE / ~/.aws/credentials) for manual runs, or the OIDC role
# assumed via aws-actions/configure-aws-credentials in CI (see oidc.tf).
# Never hardcode credentials here.
provider "aws" {
  region = var.aws_region
}
