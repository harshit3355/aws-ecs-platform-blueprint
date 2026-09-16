# Validating the platform against the brief

Every requirement, and the command that proves it. Run these yourself after
provisioning; nothing here needs to be taken on trust.

Set these once:

```bash
export AWS_REGION=ap-south-1
export MSYS_NO_PATHCONV=1   # Git Bash only: stops /ecs/... becoming a Windows path
ENV=staging                 # or prod
TF="terraform -chdir=infrastructure/terraform/environments/$ENV"
URL=$($TF output -raw application_url)
```

---

## Part 1 - Infrastructure provisioning

### VPC with public and private subnets

```bash
VPC=$($TF output -raw vpc_id)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query "Subnets[].{cidr:CidrBlock,az:AvailabilityZone,public:MapPublicIpOnLaunch}" --output table
```

Expect six subnets across two availability zones: two public, two private, two
database.

**The database tier has no route to the internet.** This is the check worth
doing, because it proves something a security group cannot give you:

```bash
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query "RouteTables[].{id:RouteTableId,routes:Routes[].{dest:DestinationCidrBlock,gw:GatewayId,nat:NatGatewayId}}" --output json
```

One route table will contain only the local VPC route: no `igw-`, no `nat-`.
That is the database tier.

### Application hosting

```bash
aws ecs describe-services --cluster meridian-$ENV --services meridian-$ENV \
  --query "services[0].{desired:desiredCount,running:runningCount,providers:capacityProviderStrategy}" --output json
```

Staging runs entirely on `FARGATE_SPOT`; production keeps an on-demand base.

### RDS PostgreSQL

```bash
aws rds describe-db-instances --db-instance-identifier meridian-$ENV \
  --query "DBInstances[0].{engine:Engine,version:EngineVersion,class:DBInstanceClass,multiAZ:MultiAZ,public:PubliclyAccessible,encrypted:StorageEncrypted,backupDays:BackupRetentionPeriod}" --output json
```

Expect `postgres` 18.6, `PubliclyAccessible: false`, `StorageEncrypted: true`.
Production additionally shows `MultiAZ: true` and 30-day backups.

### Security groups

```bash
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC \
  --query "SecurityGroups[].{name:GroupName,ingress:IpPermissions[].{port:FromPort,cidr:IpRanges[].CidrIp,fromSG:UserIdGroupPairs[].GroupId}}" --output json
```

The chain to look for: the load balancer admits `0.0.0.0/0` on port 80; the task
group admits **only the load balancer's group** on 8000; the database group
admits **only the task group** on 5432. Every hop after the first references a
security group, never a CIDR range.

### Load balancer

```bash
aws elbv2 describe-load-balancers --names meridian-$ENV \
  --query "LoadBalancers[0].{scheme:Scheme,state:State.Code,azs:AvailabilityZones[].ZoneName}" --output json
curl -s -o /dev/null -w "%{http_code}\n" $URL/health
```

### State management

```bash
aws s3api get-bucket-versioning --bucket meridian-tfstate-ACCOUNT_ID
aws s3 ls s3://meridian-tfstate-ACCOUNT_ID/ --recursive
```

Expect `Status: Enabled` and one state file per configuration. During an apply a
`.tflock` object appears beside it -- that is S3-native locking, with no
DynamoDB table anywhere.

### Variables and outputs

```bash
$TF output
```

---

## Part 2 - Deployment automation

### Tests run on pull request

```bash
gh run list --workflow=ci.yml --limit 1
```

Five jobs: lint, tests, dependency vulnerabilities, build-and-scan, workflow
lint.

### Build and push on merge to main

```bash
gh run list --workflow=cd.yml --limit 1
aws ecr describe-images --repository-name meridian \
  --query "sort_by(imageDetails,&imagePushedAt)[-1].{tags:imageTags,pushed:imagePushedAt}" --output json
```

Tags are `sha-<commit>`. There is **one** repository shared by every
environment, because promotion means the same bytes.

### Deploy to staging

```bash
curl -s $URL/health
```

The `version` field must equal the commit you pushed. That, not "the rollout
completed", is what proves the new code is serving traffic.

### Manual approval before production

```bash
gh workflow run cd.yml -f deploy_production=true
gh run watch
```

Production never runs on a push; it requires that explicit dispatch.

**Known limitation:** GitHub's *required reviewers* protection needs Pro, Team
or Enterprise on a private repository. On a free plan the API returns HTTP 422
and the environment declaration alone gates nothing. The `environment:
production` block stays in the workflow, so a named approver activates
automatically if the plan changes or the repository becomes public. Recorded as
entry 12 in the engineering log.

### Unit and integration tests

```bash
make test
make db-up && make test-integration
```

CI fails the build if integration tests are *skipped*, so a broken database
container cannot produce a green run.

### Vulnerability scanning

```bash
make audit          # dependency CVEs via pip-audit
cat .trivyignore    # every accepted finding, each with a reason and an expiry
```

Trivy runs three times in the pipeline: filesystem, then image before push, then
image again on deploy.

### Notification on failure

```bash
aws sns list-subscriptions-by-topic --topic-arn $($TF output -raw alerts_topic_arn) \
  --query "Subscriptions[].{endpoint:Endpoint,arn:SubscriptionArn}" --output table
```

A subscription showing `PendingConfirmation` has not been confirmed from the
inbox and will deliver nothing. Confirm it, then prove delivery:

```bash
aws sns publish --topic-arn $($TF output -raw alerts_topic_arn) \
  --subject "Test alert" --message "Confirming delivery"
```

---

## Part 3 - Monitoring and logging

### Infrastructure metrics

```bash
aws cloudwatch list-metrics --namespace ECS/ContainerInsights \
  --dimensions Name=ClusterName,Value=meridian-$ENV \
  --query "Metrics[].MetricName" --output text | tr "\t" "\n" | sort -u
```

CPU, memory, ephemeral storage and network, per task.

### Application metrics

```bash
curl -s $URL/metrics | grep -E "^http_requests_total|^http_request_duration" | head
```

Rate, errors and duration, labelled by handler, method and exact status code.

### Database metrics

```bash
aws cloudwatch list-metrics --namespace AWS/RDS \
  --dimensions Name=DBInstanceIdentifier,Value=meridian-$ENV \
  --query "Metrics[].MetricName" --output text | tr "\t" "\n" | sort -u | head -20
```

### Centralized logging

```bash
aws logs describe-log-groups --query "logGroups[].logGroupName" --output text | tr "\t" "\n"
```

Expect five groups: application, ECS Exec, VPC flow logs, RDS `postgresql`, and
Container Insights performance. Access logs go to S3 rather than CloudWatch:

```bash
aws s3 ls s3://$($TF output -raw alb_access_logs_bucket) --recursive | tail -3
```

Application logs are one JSON object per line, which is what lets the metric
filter match a *field* rather than a substring:

```bash
S=$(aws logs describe-log-streams --log-group-name "/ecs/meridian-$ENV/app" \
      --order-by LastEventTime --descending --limit 1 \
      --query "logStreams[0].logStreamName" --output text)
aws logs get-log-events --log-group-name "/ecs/meridian-$ENV/app" \
  --log-stream-name "$S" --limit 20 --query "events[].message" --output text \
  | tr "\t" "\n" | tail -5
```

### Dashboards

```bash
aws cloudwatch list-dashboards --query "DashboardEntries[].DashboardName" --output text
$TF output -raw cloudwatch_dashboard_url
make up     # Grafana on localhost:3000, both dashboards auto-provisioned
```

Three in total: two in Grafana, one in CloudWatch. The brief asks for at least
two.

### Alarms, proven end to end

```bash
aws cloudwatch describe-alarms --alarm-name-prefix meridian-$ENV \
  --query "MetricAlarms[].{name:AlarmName,state:StateValue}" --output table
```

Twelve. To watch one actually fire:

```bash
for i in 1 2 3 4 5 6; do curl -s -o /dev/null $URL/simulate/error; done
# meridian-<env>-application-errors moves to ALARM within about five minutes,
# and the confirmed email subscriber receives it
```

---

## Part 4 - Documentation

| Asked for | Where |
|---|---|
| How to set up and run | [runbooks/provisioning.md](runbooks/provisioning.md) |
| Architecture decisions | [adr/](adr/README.md) - eight records |
| Security considerations | README, Security |
| Cost optimization | README, Cost |
| Secret management | README - RDS-managed password, OIDC, nothing in state |
| Backup strategy | README, [runbooks/recovery.md](runbooks/recovery.md) |

The brief asks for *at least one* of secret management or backup strategy. Both
are implemented.

Prove the secret claim rather than believing it -- this is the single most
worthwhile check in this document:

```bash
$TF state pull | grep -ci password
```

Expect `0`. The database password is generated, stored and rotated by RDS; it
never passes through Terraform, so it is not in the plan, not in state, and not
visible to whoever runs the apply.

---

## Everything that needs no cloud credentials

```bash
make verify
```

Runs lint, unit tests, dependency audit, `terraform fmt`, `terraform validate`
for both environments, `promtool` against the Prometheus config and alert rules,
and every dashboard PromQL expression. This is the same set CI runs, which is
the point: if a check exists in a workflow but not in the Makefile, that is a
bug in the Makefile.
