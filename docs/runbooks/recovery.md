# Recovery runbook

Procedures for restoring service or state. Each one assumes you have AWS
credentials for the affected account and the region set correctly.

Read the whole procedure before running any of it. Every command here is
recoverable except where noted.

## Database, point in time

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier meridian-api-prod \
  --target-db-instance-identifier meridian-api-prod-restored \
  --restore-time 2026-09-14T09:30:00Z \
  --db-subnet-group-name meridian-api-prod \
  --vpc-security-group-ids <rds-sg-id>
```

Then repoint the application by updating `db_host` and rolling the service. The
restored instance is a *new* instance -- the original is left untouched, which is
what you want while an incident is still being understood.

## Database, from the final snapshot

Applies after an intentional teardown. `skip_final_snapshot = false` in
production means the snapshot exists.

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier meridian-api-prod \
  --db-snapshot-identifier <final-snapshot-id>
```

## Terraform state

The bucket is versioned, so a corrupted or truncated state file is a restore,
not a rebuild.

```bash
aws s3api list-object-versions --bucket <state-bucket> --prefix prod/terraform.tfstate
aws s3api get-object --bucket <state-bucket> --key prod/terraform.tfstate \
  --version-id <previous-version-id> terraform.tfstate
aws s3 cp terraform.tfstate s3://<state-bucket>/prod/terraform.tfstate
```

If an `apply` was interrupted and the lock is stale, remove the `.tflock` object
next to the state file. Confirm nothing is actually running first -- the lock
exists for a reason.

## Application rollback

Fastest path, no rebuild:

```
Actions > CD > Run workflow > image_tag = sha-<previous-commit>
```

This redeploys an image already in ECR, through the same gated path including
the production approval.
