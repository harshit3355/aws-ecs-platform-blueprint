# Provisioning and teardown

End-to-end, from an empty AWS account to a running service, and back to nothing.

Every command here has been run against a real account. Where something bites,
it is called out inline rather than left for you to discover.

**Order matters.** The configurations depend on each other:

```
bootstrap  ->  cicd  ->  staging / prod
(S3 state)     (IAM)     (the platform)
```

Teardown runs in the reverse order, and has more sharp edges than provisioning.

---

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Terraform | 1.16.2 | `>= 1.11` is a hard floor: S3 native state locking |
| AWS CLI | 2.32.x | Credentials with permission to create VPC, RDS, ECS, IAM, S3 |
| GitHub CLI | any recent | Only needed for the pipeline steps |
| Docker | any recent | Only for running the stack locally |

```bash
aws sts get-caller-identity     # confirm the account before anything else
export AWS_REGION=ap-south-1
```

The region matters in two places: the `aws_region` variable, and the `region`
in each `backend.hcl`. They must agree.

---

## 1. State backend (once per account)

```bash
cd infrastructure/terraform/bootstrap
terraform init
terraform apply -var "state_bucket_name=meridian-tfstate-<account-id>"
```

Bucket names are globally unique, so suffix with the account ID.

This configuration keeps **local state on purpose**: it creates the bucket every
other configuration then uses as a backend. Its own `terraform.tfstate` stays on
disk and is gitignored. Losing it costs an import, not an outage.

---

## 2. CI/CD roles (once per repository)

Only needed if you want the pipeline to deploy. Skip for a manual-only setup.

First read the OIDC subject prefix. **Do not assume it** -- see
[engineering log entry 18](../engineering-log.md):

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```

If `use_immutable_subject` is true, the prefix embeds numeric IDs
(`repo:owner@123/name@456`) and the classic `repo:owner/name` form will produce
a trust policy that silently never matches.

```bash
cd infrastructure/terraform/cicd
cp backend.hcl.example backend.hcl        # fill in the bucket name
terraform init -backend-config=backend.hcl
# set github_repository and github_subject_prefix in terraform.tfvars
terraform apply
terraform output      # two role ARNs, and the exact subjects they trust
```

The GitHub OIDC provider is read with a `data` source, never created: there can
be only one per issuer per account, so creating it would fail on any account
that already has one.

---

## 3. An environment

```bash
cd infrastructure/terraform/environments/staging
cp backend.hcl.example backend.hcl        # fill in the bucket name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

Roughly 12 minutes, almost all of it RDS. Production is the same with
`environments/prod` and takes longer because the database is Multi-AZ.

**Expect the service to be unhealthy at this point.** Terraform seeds the task
definition with a tag that does not exist yet, so tasks fail with
`CannotPullContainerError`. That is the documented bootstrap order, not a fault:
infrastructure first, then an image. The deployment circuit breaker rolls the
failed deployment back rather than leaving it stuck.

```bash
terraform output                          # ALB hostname, ECR URL, cluster, service
```

---

## 4. First deploy

Set the repository variables the pipeline reads, from the Terraform outputs:

```bash
R=<owner>/<repo>
gh variable set AWS_BUILD_ROLE_ARN  --repo $R --body "<build role arn>"
gh variable set AWS_DEPLOY_ROLE_ARN --repo $R --body "<deploy role arn>"
gh variable set ECR_REPOSITORY      --repo $R --body "meridian-staging"
gh variable set STAGING_ECS_CLUSTER --repo $R --body "meridian-staging"
gh variable set STAGING_ECS_SERVICE --repo $R --body "meridian-staging"
gh variable set STAGING_TASK_FAMILY --repo $R --body "meridian-staging"
gh variable set STAGING_URL         --repo $R --body "http://<alb-dns-name>"
```

Create the environments, then push to `main`:

```bash
for e in staging production staging-plan; do
  gh api -X PUT "repos/$R/environments/$e" --silent
done
git push origin main
```

**On the approval gate:** required reviewers on a *private* repository need
GitHub Pro, Team or Enterprise. On a free plan the API returns HTTP 422 and the
environment provides no gate at all. Production therefore also requires an
explicit `workflow_dispatch` input, which works on every plan. Add a required
reviewer as well if your plan supports it.

Deploying to production is deliberate, never automatic:

```bash
gh workflow run cd.yml -f deploy_production=true
```

---

## 5. Verify

```bash
curl -s http://<alb-dns-name>/health    # version must equal the deployed commit
curl -s http://<alb-dns-name>/readyz    # database reachable
```

`/health` reporting the SHA you just shipped is the only proof the new code is
actually serving traffic; "the rollout completed" is a weaker claim.

---

# Teardown

Reverse order: environments, then CI/CD roles, then the state bucket.

Teardown is where the safety features you asked for get in your way, which is
exactly what they are for. Everything below is a deliberate guard, not a bug.

## Before you start

`terraform destroy` on a production environment **will fail part-way** unless
you clear three guards first. Failing part-way is worse than not starting,
because you are left with a half-destroyed stack and a state file that
disagrees with reality.

### Guard 1 -- RDS deletion protection

```bash
aws rds modify-db-instance \
  --db-instance-identifier meridian-prod \
  --no-deletion-protection --apply-immediately
```

Staging has this off already. Production has it on, by design.

### Guard 2 -- ALB deletion protection

```bash
ALB=$(aws elbv2 describe-load-balancers --names meridian-prod \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB" \
  --attributes Key=deletion_protection.enabled,Value=false
```

### Guard 3 -- non-empty S3 buckets

`aws_s3_bucket` refuses to delete a bucket containing objects unless
`force_destroy` is set. Staging sets it; production does not, because access
logs are evidence.

```bash
B=$(aws s3api list-buckets \
      --query "Buckets[?starts_with(Name,'meridian-prod-alb-logs')].Name" \
      --output text)
aws s3 rm "s3://$B" --recursive
```

### ECR images

An ECR repository with images in it also blocks deletion. The Terraform
resource does not set `force_delete`, deliberately -- deleting the images is how
you lose the ability to roll back.

```bash
aws ecr batch-delete-image --repository-name meridian-staging \
  --image-ids "$(aws ecr list-images --repository-name meridian-staging \
                   --query 'imageIds[*]' --output json)"
```

## Destroy an environment

```bash
cd infrastructure/terraform/environments/prod
terraform destroy
```

Roughly 10-15 minutes. RDS is the slow part again.

**A final snapshot is taken.** Production sets `skip_final_snapshot = false`, so
destroying produces a snapshot that survives the database and continues to bill
for storage. That is the point -- it is the last line of defence against a
mistaken destroy -- but it means teardown is not complete until you decide about
it:

```bash
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].{id:DBSnapshotIdentifier,size:AllocatedStorage}' --output table
# keep it, or:
aws rds delete-db-snapshot --db-snapshot-identifier <id>
```

## What `destroy` leaves behind

Terraform removes what it created. These outlive it and cost money or block a
later rebuild:

| Left behind | Why | What to do |
|---|---|---|
| Final RDS snapshot | Created *by* the destroy | Delete once you are sure |
| Secrets Manager secret | 7-30 day recovery window | `delete-secret --force-delete-without-recovery` to reclaim the name immediately |
| CloudWatch log groups | Retention, not deletion | Delete manually if the name will be reused |
| ECR images | Not force-deleted | Delete before destroying the repository |
| S3 access logs | `force_destroy = false` in prod | Empty the bucket first |

```bash
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'rds!db')].[Name,DeletedDate]" --output table
```

A secret in its recovery window keeps its name reserved, so rebuilding the same
environment before the window expires fails with `InvalidRequestException`.

## Tear down the CI/CD roles

```bash
cd infrastructure/terraform/cicd
terraform destroy
```

Removes the two IAM roles. The OIDC provider is **not** removed -- it is read
with a `data` source, never owned by this configuration, and other projects in
the account may depend on it.

## Tear down the state backend

Deliberately awkward, and last.

```bash
cd infrastructure/terraform/bootstrap
terraform destroy
```

This **will fail**:

```
Error: Instance cannot be destroyed
Resource aws_s3_bucket.state has lifecycle.prevent_destroy set
```

That guard exists because the bucket is the only record of what exists in the
account, and every other configuration's state lives inside it. To proceed you
must remove `prevent_destroy` from `bootstrap/main.tf` by hand, which is a
deliberate speed bump rather than an obstacle.

Confirm every other configuration is destroyed first:

```bash
aws s3 ls s3://meridian-tfstate-<account-id>/ --recursive
```

Anything other than empty means a stack still exists. Delete the bucket and you
lose the ability to destroy it with Terraform.

The bucket is versioned, so emptying it requires removing versions, not just
objects:

```bash
aws s3api delete-objects --bucket <bucket> \
  --delete "$(aws s3api list-object-versions --bucket <bucket> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
```

## Confirm the spend has stopped

The expensive resources are NAT gateways, RDS instances and load balancers, in
that order. None of them stop billing until they are gone:

```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
```

Three empty lines means nothing is running.

## Cost while running

Approximate, `ap-south-1`:

| Environment | Per day | Largest item |
|---|---|---|
| Staging | ~2.20 USD | NAT gateway, not compute |
| Production | ~7 USD | Multi-AZ RDS, then NAT per AZ, then VPC endpoints |

Destroying and rebuilding staging takes about 15 minutes and costs nothing to
keep down, which is usually cheaper than leaving it up between sessions.
