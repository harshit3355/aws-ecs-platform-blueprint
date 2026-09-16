# Engineering log

Problems hit while building the platform, in the order they came up, with the
diagnosis and the fix. Entries are kept because the diagnosis is usually worth
more than the fix: several of these are failure modes that would have been much
harder to reason about after the fact, in production, under time pressure.

New entries go at the end. An entry is worth writing when the cause was not
obvious from the symptom.

---

## 1. The test suite hung forever instead of failing


The entries fall into two groups. Entries 1 to 8 were found while building the
platform. Entries 9 to 22 were found the first time it was applied to a real AWS
account and the pipeline was run against a real GitHub runner -- every one of
them passed `terraform validate`, `terraform fmt`, `tflint`, Checkov, `ruff` and
the local test suite first. That gap, between "the configuration is valid" and
"the thing actually runs", is where all of them lived.

---
**Symptom.** The first `pytest` run produced no output at all and was still
running after three minutes. Not a slow test -- zero output, including the
header pytest normally prints immediately.

**Diagnosis.** Collection was blocked in the session-scoped `database_available`
fixture, which calls `db.ping()`. There was no PostgreSQL on the machine, and
libpq's default connect timeout is *unlimited*. The connection attempt never
returned, so pytest never reached the point of printing anything.

**Resolution.** An explicit `connect_timeout` in the engine's `connect_args`:

```python
connect_args = {"connect_timeout": settings.db_connect_timeout}  # default 5s
```

Verified by timing a failed connect: it now fails in 10.2 seconds -- five per
address family, IPv6 then IPv4 -- instead of hanging.

**Why this is a production bug, not a test-environment quirk.** The same
unbounded wait applies on ECS. A security group that DROPs rather than REJECTs
(the AWS default for traffic with no matching rule) would turn "misconfigured
security group" into "every request hangs until the ALB times out at 60s". A
fast, loud failure is diagnosable; a hang is not. Fixing this in the test
environment fixed it everywhere, which is why the fix went into `services/api/db.py` rather
than into the fixture.

---

## 2. The default latency histogram could not express the p99 the dashboard asks for

**Symptom.** While writing the p99 panel, inspecting
`prometheus_fastapi_instrumentator`'s actual signature showed:

```
latency_lowr_buckets: Sequence[...] = (0.1, 0.5, 1)
```

**Diagnosis.** Three buckets. With an upper bucket boundary of 1 second,
`histogram_quantile(0.99, ...)` over the per-handler histogram cannot return any
value above one second -- it interpolates within the highest finite bucket or
returns `+Inf`. A p99 latency panel built on that is not merely imprecise; it is
structurally incapable of showing the problem it exists to show. The
higher-resolution `http_request_duration_highr_seconds` has good buckets but
carries no `handler` label, so it cannot answer "which endpoint".

**Resolution.** Explicit buckets spanning 10ms to 10s:

```python
latency_lowr_buckets = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 10)
```

**How it was caught.** Only by reading the library's actual signature rather
than trusting that a metrics library ships sensible defaults. A dashboard built
on the default would have looked perfectly healthy and been silently blind above
one second.

---

## 3. Terraform rejected the conditional ALB listener

**Symptom.** `terraform init` on the staging environment failed:

```
Error: Inconsistent conditional result types
The 'true' value includes object attribute "redirect", which is absent in
the 'false' value.
```

**Diagnosis.** The listener is a redirect when a certificate is supplied and a
forward when it is not. Those are genuinely different shapes, and HCL's ternary
requires both branches to have the same object type -- it tries to unify the two
and cannot.

**Resolution.** `merge()` a common base with a conditional fragment. `merge`
returns a map and imposes no such constraint:

```hcl
http_listener = merge(
  { port = 80, protocol = "HTTP" },
  local.https_enabled
    ? { redirect = { port = "443", protocol = "HTTPS", status_code = "HTTP_301" } }
    : { forward  = { target_group_key = "app" } },
)
```

---

## 4. A dependency cycle between the data and compute modules

**Symptom.** The RDS security group needs an ingress rule referencing the ECS
task security group. The ECS task definition needs the RDS hostname and secret
ARN. Written naively that is `data -> compute -> data`, which Terraform refuses.

**Diagnosis.** The question is not technical but about ownership: which module
*owns* the statement "these tasks may reach this database"?

**Resolution.** The compute module owns it. It takes `db_security_group_id` as
an input and creates the ingress rule itself. The dependency is then strictly
one-way. The reasoning is a comment at both ends -- at the resource in
`modules/compute/ecs.tf` and at the gap in `modules/data/main.tf` -- because a reviewer scanning
the data module would otherwise reasonably flag the missing rule as an
oversight.

---

## 5. actionlint found a script-injection hole I had written

**Symptom.**

```
ci.yml:228: "github.event.head_commit.message" is potentially untrusted.
avoid using it directly in inline scripts.
```

**Diagnosis.** The Slack notification interpolated the commit message straight
into a `run:` block inside a JSON string. `${{ }}` expressions are substituted
into the script *before* the shell parses it, so a commit message containing a
double quote would corrupt the payload -- and one crafted to close the quote
would execute arbitrary shell on the runner. On a fork pull request, the commit
message is attacker-controlled.

**Resolution.** Two changes, both necessary:

1. Untrusted values cross into the script through `env:`, never through `${{ }}`
   inside the shell body. The shell then sees a variable, not text spliced into
   its own source.
2. The JSON is built by `jq -n --arg`, so quotes and newlines are escaped
   correctly rather than by hand.

**Note.** I had already chosen `curl` over a Slack action to reduce third-party
code with access to the webhook, and introduced a worse vulnerability doing it.
The lesson is that "fewer dependencies" is not automatically "more secure", and
that the linter is the thing that actually knows.

---

## 6. No container runtime on the build machine

**Symptom.** Docker is not installed, and the WSL Ubuntu instance has no engine
either. So the Dockerfile could not be built and the compose stack could not be
started, which removed the plan to include Grafana screenshots.

**Options considered.** Installing Docker inside WSL needs interactive `sudo`
and a lot of time for one screenshot. Skipping verification entirely and
implying it worked was not an option.

**Resolution.** Two parts.

*Verify everything that can be verified, with the real tools.* Terraform 1.16.2
and Prometheus 3.14.0 were downloaded as portable binaries, so `terraform init`
ran against the real registry -- catching problem 3, and checking every module
input name against the actual module source rather than against memory -- and
`promtool` validated the scrape config, all five alert rules and all 25
dashboard PromQL expressions.

*Move image verification into CI, where a runtime exists.* The CI job does not
only build and scan the image: it runs it and asserts that `/health` returns the
expected commit SHA. That is a stronger check than a local `docker build` would
have been.

*And say so.* The README carries a verification table listing exactly what was
checked and with which tool, and states plainly that the image build and the
compose stack were not verified locally. An unverified claim presented as
verified is worse than a documented gap.

---

## 7. Integration tests that skip are worse than integration tests that fail

**Symptom.** Not a failure -- a design problem noticed while writing the
fixtures. The `db_client` fixture skips when PostgreSQL is unreachable, which is
correct on a laptop. In CI it would mean a broken service container produces a
green build with a quiet "6 skipped".

**Resolution.** The CI job runs the integration tests and then explicitly fails
if any were skipped:

```bash
if grep -qE "[0-9]+ skipped" /tmp/integration.txt; then
  echo "::error::Integration tests were skipped - PostgreSQL is not reachable"
  exit 1
fi
```

The same suite is therefore permissive locally and strict in CI, which is what
you want from both.

---

## 8. Deciding what not to build

Not a technical failure, but the judgement that shaped the result most.

Three additions were considered and deliberately cut rather than half-built.
Each is recorded so the reasoning survives the decision:

- **Alembic migrations.** Real work, and `create_all()` is adequate while the
  schema has no data behind it. Cut, documented at the call site, and written up
  in [ADR 0006](adr/0006-schema-management.md) with the hard deadline for
  revisiting it.
- **A container-level ECS health check.** Written, then removed. The ALB target
  group check plus the deployment circuit breaker already detect and replace a
  bad task; a third health check would only be a third thing to keep in sync,
  and three checks that can disagree are worse than two that cannot.
- **Per-module README files.** Folded into comments next to the resources
  instead. Documentation adjacent to the code it describes stays true;
  documentation in a separate file drifts and then actively misleads.

The general rule applied throughout: a complete, plainly-documented gap beats an
unfinished feature. Everything cut is listed in the README roadmap with the
reason, so the next person picks up a decision rather than a mystery.

---

## 9. The S3 lifecycle rule was rejected on apply

**Symptom.** `terraform apply` failed part-way:

```
api error InvalidArgument: 'Days' in the Expiration action for filter
'(prefix=)' must be greater than 'Days' in the Transition action
```

**Diagnosis.** The ALB access-log bucket transitioned objects to Infrequent
Access at a hardcoded 30 days, while expiration came from
`access_log_retention_days`. Staging sets that to 30. S3 requires expiration to
be *strictly* greater than transition, so staging was unbuildable.

Production sets 365 and was fine, which is exactly how a defect like this
survives review: the environment nobody plans carefully is the one that breaks.

**Resolution.** A `dynamic "transition"` block that is omitted when retention is
not greater than the transition threshold, plus a variable with a `validation`
enforcing S3's 30-day floor. The economics agree with the constraint: IA bills a
30-day minimum per object, so transitioning days before deletion costs more than
staying in Standard.

---

## 10. An instance class that does not exist, reported as a capacity shortage

**Symptom.** Ten minutes into the apply:

```
InsufficientDBInstanceCapacity: You can't create a db.t4g.micro database
instance because there are no Availability Zones with sufficient capacity
```

**Diagnosis.** That message describes a transient regional shortage, and the
obvious response is to wait and retry. It is not transient:

```
aws rds describe-orderable-db-instance-options \
  --engine postgres --engine-version 18.6 --db-instance-class db.t4g.micro
```

returns **zero** results in `ap-south-1`, and the same for 17.11 and 16.15.
`db.t4g.micro` is simply not offered for PostgreSQL in this region. The smallest
orderable Graviton class is `db.t4g.small`.

**Resolution.** Changing the value would have fixed the symptom and left the
trap. The module now asks AWS at plan time:

```hcl
data "aws_rds_orderable_db_instance" "selected" {
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class
  storage_type   = "gp3"
}
```

Its output feeds the instance class, so the dependency is real rather than
decorative. An unavailable combination now fails during `plan` with an accurate
message instead of ten minutes into an apply with a misleading one.

---

## 11. The default image tag could never exist

**Symptom.** The service came up and immediately failed:

```
CannotPullContainerError: ...meridian-staging:latest: not found
```

**Diagnosis.** `image_tag` defaulted to `latest`, but the pipeline only ever
pushes `sha-<commit>`, and the ECR repository is `IMMUTABLE`. Nothing would ever
create that tag. Every first apply therefore produced a service that could not
start.

**Resolution.** The bootstrapping order is now explicit: infrastructure is
applied, the pipeline publishes an image, and only then can a task run. The
deployment circuit breaker means the failed rollout reverts rather than hanging.

---

## 12. The manual approval gate did nothing

**Symptom.** Setting a required reviewer on the `production` environment
returned HTTP 422:

```
Failed to create the environment protection rule. Please ensure the billing
plan supports the required reviewers protection rule.
```

**Diagnosis.** Environment protection rules are free on **public** repositories.
On a **private** repository they require GitHub Pro, Team or Enterprise. This
repository is private on a free plan, so `environment: production` in the
workflow was decorative: the job would have run unattended.

This is the most consequential entry in this log. A manual approval before
production is a core requirement, the workflow appeared to implement it, and
nothing in the repository could have revealed that it did not.

**Resolution.** Production now additionally requires an explicit
`workflow_dispatch` input, which is a human action that works on every plan. The
`environment:` declaration stays, so a named approver is added automatically if
the repository becomes public or the plan changes. Belt and braces, because only
one of them holds today.

---

## 13. A test that asserted on a default while reading the environment

**Symptom.** `test_tls_is_requested_by_default` passed locally and failed in CI:

```
AssertionError: assert 'disable' == 'require'
```

**Diagnosis.** The test asserted that `db_sslmode` defaults to `require`. CI
exports `DB_SSLMODE=disable` for its throwaway PostgreSQL, which has no TLS, and
`pydantic-settings` reads the environment. The test was reading ambient
configuration and calling it a default.

**Resolution.** `monkeypatch.delenv("DB_SSLMODE", raising=False)` first. A test
that reads its environment is not testing a default, and the only reason it ever
passed was that the local machine happened not to set the variable.

---

## 14. The image could never build

**Symptom.** `pip install` exited 2 on every build:

```
--require-hashes option does not take a value
```

**Diagnosis.** The Dockerfile passed `--require-hashes=false`. It is a flag, not
a valued option. It was also pointless, since hash checking is off by default --
written to look deliberate, achieving nothing, and breaking the build.

**Resolution.** Removed.

---

## 15. Five classes of infrastructure misconfiguration

**Symptom.** Trivy's filesystem scan failed the build with HIGH and CRITICAL
findings across the load balancer, the task security group, the S3 buckets and
the SNS topic.

**Diagnosis and resolution.** Split into two groups.

*Fixed:* the SNS topic was unencrypted. Alarm payloads carry resource
identifiers and fragments of application error text, and the AWS-managed key
costs nothing.

*Accepted, with reasons:* the load balancer is public because it is a public web
service; the HTTP listener forwards directly only where no certificate exists;
task egress is unrestricted until VPC endpoints and prefix lists land; and ALB
access-log delivery supports SSE-S3 only, so a customer-managed key would
silently stop log delivery rather than fail.

Inline `trivy:ignore` comments were tried first and are not sufficient: several
findings are raised against `terraform-aws-modules` source downloaded into
`.terraform/`, which is not ours to annotate. Each acceptance now lives in
`.trivyignore` with a justification and, where temporary, an expiry date.

The alternative was `soft_fail` or a lower severity threshold. Both would have
kept the build green and turned the scanner into something nobody reads.

---

## 16. actionlint found something locally impossible to find

**Symptom.** `actionlint` passed on the development machine and failed in CI:

```
shellcheck reported issue in this script: SC2034:warning: i appears unused
```

**Diagnosis.** actionlint shells out to `shellcheck` for `run:` blocks *when
shellcheck is installed*. GitHub runners have it; this machine does not. The
same binary and version therefore performs a different set of checks depending
on where it runs.

**Resolution.** Fixed the unused loop variables. Worth recording because "it
passes locally" was true and meaningless -- a local check that silently performs
fewer checks than CI is worse than no local check, because it creates false
confidence.

---

## 17. Coverage measured a directory that no longer existed

**Symptom.** Every CI run printed `CovReportWarning: Failed to generate report:
No data to report` and passed anyway.

**Diagnosis.** `--cov=app` survived the move of the service to `services/api`.
Coverage was measuring an empty path, reporting nothing, and failing nothing.

**Resolution.** Corrected the path. The real lesson is that a check which cannot
fail is not a check; this one had been decorative since the restructure.

---

## 18. An OIDC trust policy that could never match

**Symptom.** Every attempt to assume the deploy role failed, through twelve
built-in retries and a full re-run:

```
Could not assume role with OIDC: Not authorized to perform
sts:AssumeRoleWithWebIdentity
```

The role ARN was right, the audience condition was right, the workflow had
`id-token: write`, and the trust policy read correctly on inspection.

**Diagnosis.** The subject claim was not what every guide says it is. Asking
GitHub directly:

```
$ gh api repos/OWNER/REPO/actions/oidc/customization/sub
{"use_default":true,"use_immutable_subject":true,
 "sub_claim_prefix":"repo:harshit3355@96806109/aws-ecs-platform-blueprint@1368873348"}
```

GitHub has rolled out **immutable subject claims**, which embed the numeric
owner and repository IDs rather than their names:

```
repo:owner@96806109/name@1368873348:ref:refs/heads/main
```

The trust policy contained the classic `repo:owner/name:ref:refs/heads/main`
form, which now matches nothing. The change is a genuine security improvement --
renaming an account can no longer silently transfer trust to whoever claims the
old name -- but it invalidates every OIDC example written before the rollout.

What made it expensive was the error message. "Not authorized" reads as a
permissions problem, so the search went to policies, audiences and propagation
delay before reaching the string itself.

**Resolution.** The prefix is an explicit variable rather than something
assembled from the repository name, with the command to read the real value in
its description. Assembling it from the name produces a policy that silently
never matches.

---

## 19. Twelve fixable CVEs frozen into a pinned base image

**Symptom.** The image scan failed with 12 HIGH and CRITICAL vulnerabilities in
Debian packages, all with fixes available.

**Diagnosis.** Pinning the base image by digest fixes the starting point and
also freezes whatever CVEs that layer shipped with. ADR 0008 predicted this in
writing: *"Updates do not arrive on their own. Without automation the pins go
stale, which trades a supply-chain risk for a patching risk."* That is precisely
what happened, and faster than expected.

**Resolution.** The runtime stage applies OS security updates at build time.
This trades bit-identical rebuilds for patched ones, which is the right way
round: the alternative is a perfectly reproducible image full of known, fixed,
unpatched vulnerabilities. The scan runs after the upgrade, so a regression
still fails the build.

The proper fix is automated dependency updates raising reviewable pull requests.
It is the second item on the roadmap for this reason.

---

## 20. A vulnerability that moved when looked at

**Symptom.** After pinning `setuptools==84.0.0`, the scanner still reported
`setuptools 70.3.0`.

**Diagnosis.** The contradiction was the clue: the reported version was not the
pinned version, so the finding was not in the place being pinned. The
virtualenv at `/opt/venv` correctly contained 84.0.0. The copy being reported
was the *interpreter's own* `site-packages`, shipped inside the base image,
which `requirements.txt` has no influence over whatsoever.

More pinning would never have fixed it. The application runs entirely from the
virtualenv and never touches system `site-packages`.

**Resolution, and an honest limit.** The system build toolchain is removed from
the runtime image -- `pip uninstall` did not remove it, a path glob did not match
it, and a filesystem search across `/usr/local` did not clear the finding either.
Removing a package installer from a running container is worth doing on its own
merits, so that change stays.

After three attempts the file still could not be located without a container
runtime to inspect the image interactively, and this machine has none. The
finding is therefore accepted in `.trivyignore` with its reachability written
out: the vulnerable code path is `PackageIndex`, which runs only when setuptools
downloads packages from an index. The container starts uvicorn from the
virtualenv, installs nothing, and runs non-root on a read-only root filesystem.
There is no path from a request to that code.

That is a reasoned acceptance, not a silenced alarm, and the distinction is the
point: the entry carries an expiry date and a note to delete rather than renew
it once the base image ships a patched version. A VEX statement asserting
`not_affected` with justification `vulnerable_code_not_in_execute_path` is the
correct long-term fix and is on the roadmap.

---

## 21. An unrelated role in the account was assumable by anyone

**Symptom.** Found while checking whether an OIDC provider already existed.

**Diagnosis.** A pre-existing role, `github-actions-terraform-apply`, carried
`AdministratorAccess` with this trust condition:

```json
"StringLike": { "token.actions.githubusercontent.com:sub": "repo:ciATH*" }
```

The `*` matches everything after `ciATH`, including the `/` separating owner
from repository. GitHub account names are global and free to register, so anyone
able to register an account beginning with those characters could assume an
AdministratorAccess role in the account.

**Resolution.** Reported, not changed -- it belongs to another project and was
explicitly out of scope. Recorded here because it is the strongest possible
argument for the rule applied throughout this repository: **`StringEquals` on
exact subjects, never `StringLike` on a prefix.** A wildcard in a trust policy
is not a convenience; it is the whole boundary, removed.

---

## 22. One OIDC provider per account

**Symptom.** The first draft created `aws_iam_openid_connect_provider` as a
resource. The account already had one.

**Diagnosis.** The GitHub OIDC provider is an account-level singleton: there can
be exactly one per issuer. Applying would have failed with
`EntityAlreadyExists`, and the alternative -- importing it -- would have put a
shared account-level resource under this project's state, so destroying this
project would break every other consumer.

**Resolution.** A `data` source, never a `resource`. The configuration composes
with whatever already exists rather than claiming ownership of it.

---

## 23. One registry per environment contradicts promoting one artifact

**Symptom.** Applying production created a second container registry,
`meridian-prod`, alongside `meridian-staging`. Nothing ever pushed to it.

**Diagnosis.** The compute module created a registry per environment, but the
pipeline is built on the opposite idea: build an image once and promote that
same artifact through staging to production. Only one of the two registries
could ever hold the image being promoted, so the other was dead weight -- and
worse than dead weight, because an empty `meridian-prod` invites someone to
"fix" it later by rebuilding for production, which is a different artifact
however identical the inputs look.

**Resolution.** One registry, moved into the delivery configuration alongside
the CI roles. It now also outlives environments, so tearing one down no longer
destroys the images you would roll back to.

---

## 24. The pipeline refilled a registry during its own teardown

**Symptom.** `terraform destroy` failed on a repository emptied minutes earlier:

```
RepositoryNotEmptyException: repository 'meridian-staging' cannot be deleted
because it still contains images
```

**Diagnosis.** Documentation commits pushed to `main` while the teardown was
running. Those triggered the delivery workflow, which built and pushed a fresh
image into the repository being destroyed.

**Resolution.** The runbook now disables the workflow before teardown begins.

The general shape is worth naming, because it keeps recurring in this log: the
steady state was fine and the *transition* was not. Entry 9 was an environment
whose lifecycle rule only failed at one retention value; entry 11 was the window
between infrastructure existing and an image existing; this one is the window
between emptying a registry and deleting it. Configuration review examines
steady states. Only running the transition finds these.

---

## 25. A smoke test that could never have passed

**Symptom.** CI failed with the container refusing to serve anything:

```
curl: (7) Failed to connect to localhost port 8000
Error: Image failed to serve /health within 60s
```

**Diagnosis.** The smoke test started the image with `DB_HOST=127.0.0.1` and
nothing listening, on the reasoning that `/health` deliberately does not query
the database. The reasoning was wrong in a way worth recording: startup is
fail-fast by design, so schema initialisation exhausted its retries, uvicorn
exited, and `/health` was never served at all. The endpoint not *needing* a
database does not mean the process can *start* without one.

It had also never actually run before. Earlier builds failed at the image scan,
one step before it, so the step had been present and unexercised for days --
green-looking because it never got a chance to be red.

**Resolution.** The smoke test now runs a real PostgreSQL container on a shared
Docker network, and additionally asserts `/readyz`, which exercises the database
leg the previous version could not reach.

---

## 26. An orphaned .pth file left a traceback in every log line

**Symptom.** Every container start printed:

```
Error processing line 1 of /opt/venv/.../distutils-precedence.pth:
  ModuleNotFoundError: No module named '_distutils_hack'
```

**Diagnosis.** Removing setuptools from the virtualenv (entry 20) deleted
`_distutils_hack` but left `distutils-precedence.pth`, which imports it at
every interpreter start. Harmless -- Python reports it and continues -- but it
interleaved a traceback with the structured JSON logs, which is precisely the
noise the structured logging exists to avoid.

**Resolution.** Remove the `.pth` alongside the module. Deleting a package means
deleting what registers it, not only its code.

---

## 27. A permission scoped to a name pattern the resource stopped matching

**Symptom.** The delivery pipeline built and scanned the image, then failed to
push it:

```
User: .../meridian-github-build is not authorized to perform:
ecr:InitiateLayerUpload on resource: .../repository/meridian
```

**Diagnosis.** The build role granted ECR push on
`arn:aws:ecr:*:<account>:repository/meridian-*`. That matched the old
per-environment repositories, `meridian-staging` and `meridian-prod`. Entry 23
replaced them with one shared repository named exactly `meridian` -- which the
pattern `meridian-*` does not match, because it requires the hyphen.

Consolidating the registry and scoping the permission were the same change, made
in the same commit, and the second half was not revisited.

**Resolution.** The repository is now defined in the same configuration as the
role, so the policy references `aws_ecr_repository.app.arn` directly. There is
no pattern left to drift out of alignment with the thing it is meant to describe.

The same pass tightened the deploy role's ECR read permissions, which had been
lumped in with `GetAuthorizationToken` and therefore scoped to `*`.
`GetAuthorizationToken` genuinely accepts no resource ARN; `DescribeImages` and
`BatchGetImage` do. Splitting them into two statements scopes the two that can
be scoped.

**The pattern worth naming.** A least-privilege policy written as a string
pattern is coupled to a naming convention, and nothing enforces that coupling.
It fails *open* in the sense that it is silent: `terraform validate`, `plan` and
`apply` all succeed, and you find out at push time. Referencing the resource
directly makes the coupling structural, so the permission cannot drift away
from the thing it authorises.

---

## 28. An alarm that had never once been true

**Symptom.** With the service verifiably healthy -- `/health` returning 200,
`/readyz` reaching the database, one task running -- one alarm sat in ALARM:

```
meridian-staging-ecs-no-running-tasks   ALARM
"no datapoints were received for 3 periods and 3 missing datapoints
 were treated as [Breaching]"
```

**Diagnosis.** `RunningTaskCount` does not exist in the `AWS/ECS` namespace.
That namespace publishes `CPUUtilization`, `MemoryUtilization` and
`LiveTaskCount`. `RunningTaskCount` comes from `ECS/ContainerInsights`.

The alarm had therefore never evaluated a real datapoint in its life. It went
into ALARM shortly after creation and stayed there.

The same repository already had this right in one place and wrong in another:
the CloudWatch dashboard queries `ECS/ContainerInsights` for exactly this
metric. Alarm and dashboard disagreed about where the data lives, in adjacent
files, and nothing flagged it -- CloudWatch accepts any namespace and metric
name as a string, valid or not.

**Resolution.** Correct the namespace.

**The asymmetry worth understanding.** This alarm sets
`treat_missing_data = "breaching"`, on the reasoning that a service reporting no
task count at all is worse news than one reporting zero. That reasoning is
sound, and it is also what made a typo visible: the alarm screamed continuously
until someone looked.

Had it been `notBreaching`, the identical mistake would have produced an alarm
that sat permanently in OK, silent, and would have stayed silent through a real
outage. That is strictly worse and far harder to notice.

Neither setting makes a wrong metric name safe. What does is checking that an
alarm has ever evaluated real data:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix <prefix> \
  --query "MetricAlarms[?StateReason!=null].{name:AlarmName,reason:StateReason}"
```

Any alarm whose reason mentions missing datapoints is not monitoring anything.
A permanently-firing alarm and a never-firing one are the same defect wearing
different clothes, and the noisy one is the lucky case.
