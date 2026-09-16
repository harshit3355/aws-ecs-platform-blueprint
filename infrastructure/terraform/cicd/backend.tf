terraform {
  backend "s3" {
    # IAM roles do not belong in unlocked local state: two concurrent applies
    # against a trust policy is precisely the race you do not want, and the
    # history of who changed an access boundary and when is worth keeping.
    key          = "cicd/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
