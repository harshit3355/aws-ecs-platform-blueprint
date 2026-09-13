# Engineering log

Problems hit while building the platform, in the order they came up, with the
diagnosis and the fix. Entries are kept because the diagnosis is usually worth
more than the fix: several of these are failure modes that would have been much
harder to reason about after the fact, in production, under time pressure.

New entries go at the end. An entry is worth writing when the cause was not
obvious from the symptom.

---

## 1. The test suite hung forever instead of failing

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
