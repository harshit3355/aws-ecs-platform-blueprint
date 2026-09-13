# 0006 - Schema created at startup, migrations deferred

**Status:** Accepted, revisit before the first production dataset

## Context

The service owns its schema and is currently its only writer. Two options:

1. `Base.metadata.create_all()` at application startup.
2. Alembic, with a migration step in the deployment pipeline.

Option 2 is correct for any service holding data that matters. It is also a
standing commitment: a migration directory, a review convention, a pipeline
step, and a rollback story for schema changes that cannot be reversed.

## Decision

`create_all()` at startup, with a bounded retry while the database finishes
coming up. The call is idempotent and creates missing tables only.

The limitation is recorded in the code at the point where it applies, not only
here, so that anyone reading `_init_schema` sees it.

## Consequences

Gained:

- No migration tooling to operate while the schema is still changing shape.
- A fresh environment is usable the moment the first task starts.

Given up -- and these are the reasons this ADR is marked *revisit*:

- **No column or type changes.** `create_all` creates missing tables. It will
  not alter an existing one, so a changed column silently does nothing and the
  application fails at query time instead.
- **No ordering guarantee.** Several tasks starting together each run
  `create_all` concurrently.
- **No down path.** There is nothing to revert.

## The replacement, when it comes

Alembic, invoked as a one-off ECS task using the same task definition and the
same secret, run by the pipeline *before* `update-service`:

```
aws ecs run-task --overrides '{"containerOverrides":[{"command":["alembic","upgrade","head"]}]}'
```

Running it as a separate task rather than in the container entrypoint means it
runs exactly once per deploy, its exit status gates the rollout, and its logs
are separable from application logs.

## Revisit when

Before the first environment holds data that cannot be recreated. That is the
hard deadline; `create_all` stops being acceptable the moment a dropped table
is an incident rather than an inconvenience.
