# Contributing

## Getting set up

```bash
make install     # virtualenv + dev dependencies
make up          # api, postgres, prometheus, grafana
make verify      # everything CI runs that needs no credentials
```

`make help` lists every target. If a check runs in CI but has no target here,
that is a bug in the `Makefile` -- please fix it in the same pull request.

To stand the infrastructure up yourself, or take it down again, follow
[docs/runbooks/provisioning.md](docs/runbooks/provisioning.md). Teardown in
particular has guards that will stop a `terraform destroy` part-way if you have
not cleared them first.

## Repository layout

| Path | Owns |
|---|---|
| `services/` | Application code. One directory per deployable service. |
| `infrastructure/terraform/modules/` | Reusable infrastructure, split by lifecycle |
| `infrastructure/terraform/environments/` | Per-environment composition. Values only, no new resources. |
| `platform/observability/` | Prometheus config, alert rules, Grafana dashboards |
| `scripts/` | Repository-level checks invoked by the `Makefile` and CI |
| `docs/adr/` | Decisions. See [the ADR index](docs/adr/README.md). |

Modules are split by **lifecycle**, not by resource type: `network` changes
almost never, `data` changes in a maintenance window, `compute` changes on every
deploy, `observability` changes whenever a threshold turns out to be wrong.
Splitting by resource type -- all security groups here, all IAM there -- reads
tidily and makes every routine change touch every module.

The module dependency graph is strictly one-way:

```
network -> data -> compute -> observability
```

If a change needs an edge that points backwards, that is a signal the resource
is in the wrong module, not a reason to add the edge.

## Making a change

1. Branch from `main`.
2. Make the change. Add or update tests.
3. `make verify`.
4. Open a pull request. CI runs the same checks plus the container build,
   image scan and infrastructure scans.

### Commit messages

Conventional Commits, with a body explaining **why**:

```
feat(compute): add request-count scaling policy

CPU stays flat on an I/O-bound service while latency climbs, so CPU-based
scaling reacts late. Request count per target moves first.
```

The subject says what changed; the diff already shows that. The body is the
part that is not recoverable from the code, so it is the part that matters.

## Conventions

**Terraform.** Every variable has a `type` and a `description`. Constraints that
can be expressed as `validation` blocks are. Security group rules are discrete
`aws_vpc_security_group_ingress_rule` resources with a `description`, and they
reference other security groups rather than CIDR ranges wherever the source is
something we run.

**Python.** `ruff` decides formatting and lint; there is nothing to argue about.
Public functions have docstrings that say why, not what.

**Comments.** Write them where the reasoning is not visible in the code -- a
non-obvious constraint, a deliberate trade-off, a setting whose default is
wrong. Do not narrate what the next line does.

**Dependencies.** Pinned to immutable identifiers: commit SHAs for Actions,
digests for base images, `==` for Python packages. See
[ADR 0008](docs/adr/0008-supply-chain-pinning.md).

## Changing infrastructure

- Modules hold resources. Environments hold values. If a pull request adds a
  resource to `environments/`, it probably belongs in a module.
- A change that applies to only one environment is a variable with different
  values, not a different module.
- `terraform plan` output is posted to the pull request when AWS credentials
  are configured. Read it. A plan that destroys and recreates a stateful
  resource needs saying so in the pull request description.

## Adding a decision record

Anything that a future reader would otherwise reverse without knowing the cost
gets an ADR. Copy the structure of an existing one, number it sequentially, and
add it to the index table.

Do not edit an accepted record to reflect a change of mind. Write a new one that
supersedes it and mark the old one `Superseded`. The history is the value.
