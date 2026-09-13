# 0003 - S3 backend with native state locking

**Status:** Accepted

## Context

Terraform state must be shared, durable, and protected against two engineers
applying at once. The long-standing pattern is an S3 bucket for the state plus a
DynamoDB table for the lock.

Terraform 1.11 made S3-native locking generally available: the backend writes a
`.tflock` object next to the state file and uses S3's conditional writes for
mutual exclusion.

## Decision

S3 with `use_lockfile = true`. No DynamoDB table.

The bucket is created by a separate `bootstrap` configuration that keeps local
state, applied once. That configuration is the one place where local state is
correct: it creates the thing every other configuration uses as a backend.

## Consequences

Gained:

- One less resource to create, pay for, tag, monitor and eventually fail to
  clean up.
- The lock lives beside the state it protects, so a stale lock is visible to
  anyone listing the prefix rather than hidden in another service.
- Bucket versioning becomes the recovery story for both state and lock.

Given up:

- A hard floor of Terraform 1.11. Older versions silently ignore `use_lockfile`
  and run without a lock, so `required_version >= 1.11` is set in every
  configuration rather than left implicit.
- DynamoDB's lock table was queryable with familiar tooling; an S3 object is
  slightly less convenient to inspect.

## Revisit when

Never, in the absence of a regression. If the Terraform floor ever has to drop
below 1.11 for an unrelated reason, the DynamoDB table comes back with it.
