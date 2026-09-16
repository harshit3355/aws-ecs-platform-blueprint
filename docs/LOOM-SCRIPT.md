# Loom walkthrough script

**Target length:** 10-12 minutes, six sections of roughly two minutes each.

### Before you record

- Generate error traffic so the dashboards are not uniformly green:
  `for i in $(seq 1 8); do curl -s $URL/simulate/error; done`
- Open tabs in this order: repo, VPC, ECS, RDS, CloudWatch dashboard, GitHub Actions
- Increase your terminal font so it is readable at 720p

**Rule for the whole video:** for every screen, say *what it is*, then *why it is
that way*. The second half is what gets remembered.

---

## 0. Opening (30 seconds)

- A containerised Python service on AWS: Terraform for infrastructure, GitHub
  Actions for delivery, Prometheus and CloudWatch for monitoring
- The application is deliberately small; the point is that it is *operable* -
  deployable, observable, recoverable
- Everything shown was destroyed and rebuilt from this repository today, so what
  is running is what is committed

---

## 1. Repository layout (90 seconds)

Show the repo root.

- `services/api` - the application
- `infrastructure/terraform` - bootstrap, modules, environments
- `platform/observability` - Prometheus config, Grafana dashboards
- `docs/` - decision records, runbooks, engineering log
- `Makefile` - every check CI runs, runnable locally

**The point to make:** modules are split by **lifecycle**, not by resource type.

- `network` changes almost never
- `data` changes in a maintenance window
- `compute` changes on every deploy
- `observability` changes when a threshold turns out to be wrong

Say: *"Splitting by resource type - all security groups here, all IAM there -
reads tidily and makes every routine change touch every module."*

Open `docs/adr/` briefly.

- Eight decision records
- Each records the *cost* of the decision, not just the decision, so it does not
  get re-argued by whoever joins next

---

## 2. Infrastructure (2 minutes)

VPC resource map.

- Six subnets, two availability zones, three tiers
- Click a `db` subnet, then open its route table

Say slowly: *"The database tier has no route to the internet. Not a blocked
route - an absent one. That makes 'the database cannot call out' a property of
routing, rather than a security group rule somebody can widen under pressure."*

Security groups - trace the chain out loud.

- Internet to load balancer on 80
- Load balancer group to tasks on 8000
- Task group to database on 5432
- No egress rules at all on the database group

Say: *"Every hop after the first references a security group, never a CIDR range.
A CIDR is correct only until somebody reuses the subnet. A group reference means
whatever is running the application, which survives every deploy."*

RDS page.

- PostgreSQL 18.6, encrypted, Publicly accessible: **No**, backups enabled
- Configuration tab, then follow the Secrets Manager link

**Strongest single point in the video:**

*"The master password is generated, stored and rotated by RDS. It never passes
through Terraform - not in the plan, not in state, not visible to whoever runs
the apply. The pattern most examples use writes that password into state in
plaintext, which quietly makes the state bucket a credential store."*

---

## 3. Delivery pipeline (2-3 minutes)

GitHub Actions tab.

- **CI on pull requests:** lint, unit tests, integration tests, dependency audit,
  container build and scan, workflow lint
- **CD on merge:** build, scan, push, deploy staging, then production behind a gate

Open `.github/workflows/cd.yml`. Four things to point at:

- **Built once, promoted.** *"Production deploys the exact artifact staging ran.
  A rebuild is a different artifact however identical the inputs look."*
- **Scanned before the push.** *"A vulnerable image never reaches the registry,
  so nobody can pull the latest build while a fix is still in flight."*
- **Verification checks the version.** *"After the rollout the pipeline polls
  /health until it returns the commit SHA it just shipped. The rollout completed
  and the new code is serving traffic are different claims."*
- **Actions pinned to commit SHAs.** *"Tags are movable. In March 2026 a widely
  used scanning action had its tags retargeted at a credential stealer, and every
  workflow pinned to a tag picked it up automatically. A commit SHA cannot be
  repointed."*

Show a green run, then the production job.

- Production requires an explicit dispatch; it never runs on a push
- Be straight about the limitation: GitHub's required-reviewers protection needs
  a paid plan on a private repository, so there is a second gate that works on
  any plan. The environment declaration stays, so a named approver activates
  automatically if the plan changes

---

## 4. Monitoring and logging (2 minutes)

CloudWatch dashboard.

- Load balancer request rate, 5xx, p99 latency, target health
- ECS CPU, memory, task count
- RDS CPU, connections, free storage, IOPS
- Live log query showing recent errors

Grafana, both dashboards.

- Service RED - rate, errors, duration by endpoint
- Infrastructure and Database

Say: *"Three dashboards, split by what each tool can actually see. Prometheus
cannot see managed services; CloudWatch cannot see inside the process."*

Say: *"Dashboards are JSON in version control with UI edits disabled. A dashboard
clicked together in a browser cannot be rebuilt after someone deletes it."*

Log groups - open the application group.

- One JSON object per line
- *"That is what lets the metric filter match a field rather than a substring. A
  substring filter would also fire on the word ERROR inside user-supplied text."*

Alarms page.

- Twelve alarms
- Show the error alarm transitioning, after the traffic you generated

---

## 5. What went wrong, and what I did (2 minutes)

**This is the section that separates the submission. Do not skip it.**

Open `docs/engineering-log.md`.

- Twenty-eight problems, each with the diagnosis, not just the fix
- Every one passed `terraform validate`, `fmt`, `tflint`, Checkov and the local
  test suite before it was found

Pick two or three. The strongest:

**The alarm that had never been true**

- `RunningTaskCount` is not in the `AWS/ECS` namespace - it is in Container
  Insights. The alarm had never evaluated a real datapoint; it sat in ALARM from
  creation
- *"What makes it interesting is the asymmetry. It treated missing data as
  breaching, so it screamed until someone looked. The same typo the other way
  round would have sat silently in OK and stayed silent through a real outage. A
  permanently firing alarm and a never firing one are the same defect - the noisy
  one is the lucky case."*

**The permission scoped to a name pattern**

- Two registries were consolidated into one, and the IAM policy still granted
  push on `meridian-*`, which does not match a repository named exactly
  `meridian`
- Terraform validated, planned and applied happily; it failed at `docker push`
- *"The fix was not a better wildcard. The repository is now defined in the same
  configuration as the role, so the policy references its ARN directly and there
  is no pattern left to drift."*

**The instance class that did not exist**

- AWS reported `InsufficientDBInstanceCapacity`, which reads as a transient
  regional shortage
- It was not transient - that instance class is not offered for PostgreSQL in
  this region at all
- The fix queries AWS at plan time, so the failure now happens before anything is
  created, with an accurate message

Close the section:

*"The pattern across most of these is the same - the steady state was fine and
the transition was not. Configuration review inspects steady states. Only running
the thing finds the rest."*

---

## 6. Close (45 seconds)

- Both optional items implemented, not one: secret management **and** backup
  strategy
- Show `docs/VALIDATION.md` - every requirement mapped to a command, so the
  claims can be checked rather than believed
- Show the roadmap - what was deliberately not built, and why: migrations,
  automated dependency updates, blue/green, WAF, tracing
- The whole platform tears down and rebuilds from the runbook; that was done
  immediately before recording

---

## Things to avoid

- Do not read the README aloud. Show the thing, then say why it is that way
- Do not claim anything you have not seen work. HTTPS is not wired because there
  is no domain - say so. A documented gap reads better than a glossed one
- Do not rush section 5. Anyone can provision infrastructure from a tutorial;
  the debugging is the differentiator
- If you are asked a question you do not know the answer to, say so and say where
  you would look. That answers better than a guess
