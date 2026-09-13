# 0004 - RDS-managed master password

**Status:** Accepted

## Context

The database needs a master password. The widely-copied Terraform pattern is:

```hcl
resource "random_password" "db" { length = 32 }
resource "aws_secretsmanager_secret_version" "db" {
  secret_string = random_password.db.result
}
```

That works, and it has a property people rarely state out loud: the generated
password is written into Terraform state **in plaintext**. Every engineer who
can run `terraform apply`, every CI job that can read the state bucket, and
every copy of the state file can read the production database password. The
state bucket quietly becomes a credential store, with none of the access
controls, rotation, or audit trail a credential store is supposed to have.

## Decision

`manage_master_user_password = true` on the RDS instance. RDS generates the
password inside AWS, stores it in Secrets Manager, and rotates it on a schedule.

Terraform never receives the value. It is not in the plan output, not in state,
and not visible to whoever runs the apply. Terraform only learns the secret's
ARN.

The ECS task definition references individual JSON keys within that secret
(`<secret-arn>:password::`), so the container receives only the field it needs,
and the task execution role is scoped to exactly that one secret ARN.

## Consequences

Gained:

- No database credential exists in Terraform state, in any plan artefact, or in
  CI logs.
- Rotation is a managed schedule rather than a runbook step, and the
  application picks up the new value on its next task start because it reads
  the secret at boot.
- The blast radius of read access to the state bucket no longer includes the
  database.

Given up:

- Terraform cannot seed a known password, so any tooling that expected to read
  it from state must read it from Secrets Manager instead.
- Rotation restarts tasks eventually; connection pools must tolerate
  re-authentication. `pool_pre_ping` in the service covers this.

## Revisit when

An external consumer needs the credential and cannot call Secrets Manager. The
answer then is to grant that consumer read access to the secret, not to move
the password back into state.
