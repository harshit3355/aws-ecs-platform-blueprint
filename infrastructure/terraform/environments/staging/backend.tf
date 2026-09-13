terraform {
  backend "s3" {
    # Values are supplied at init time rather than hardcoded, because the bucket
    # name is account-specific:
    #
    #   terraform init -backend-config=backend.hcl
    #
    # See backend.hcl.example. Running `init -backend=false` skips this entirely,
    # which is how validation runs in CI without any AWS credentials.
    key     = "staging/terraform.tfstate"
    encrypt = true

    # Native S3 state locking, generally available since Terraform 1.11. It
    # replaces the DynamoDB lock table that every older example still creates --
    # one fewer resource to provision, pay for and forget to clean up.
    use_lockfile = true
  }
}
