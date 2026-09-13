# 0005 - The pipeline owns the image, Terraform owns the shape

**Status:** Accepted

## Context

Both Terraform and the delivery pipeline can set an ECS service's task
definition. If both do, they fight: the pipeline deploys `sha-abc123`, then the
next `terraform apply` -- run for an unrelated reason, such as widening a
security group -- reverts the service to whatever image tag is written in the
committed configuration.

The same conflict exists for `desired_count`, which the autoscaler changes
continuously.

## Decision

Terraform owns the *shape* of the service: CPU, memory, roles, secrets,
networking, log configuration, capacity providers, scaling policy bounds.

The pipeline owns the *contents*: which image runs. The autoscaler owns how many
tasks run.

The service declares this explicitly:

```hcl
lifecycle {
  ignore_changes = [task_definition, desired_count]
}
```

The pipeline reads the live task definition, changes only the image and the
version label, and registers a new revision. Everything Terraform set is
preserved automatically.

## Consequences

Gained:

- `terraform apply` is safe to run at any time. It cannot roll production back.
- The pipeline does not need a copy of the task definition in the repository,
  so there is no second definition to drift out of sync.

Given up:

- `terraform plan` no longer reports which image is running. Answering that
  requires `aws ecs describe-services` or the deployment history, both of which
  are better sources anyway.
- A genuine Terraform-side change to the container definition needs the service
  to be rolled by the pipeline before it takes effect on running tasks.

## Revisit when

A deployment tool takes over the service entirely -- for example CodeDeploy
blue/green, which manages the task definition and listener rules itself. The
ignore list would then grow rather than shrink.
