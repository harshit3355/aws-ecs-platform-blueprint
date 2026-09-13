# Architecture Decision Records

Short records of decisions that were not obvious, taken in the order they were
made. Each one states what was actually decided, what it cost, and what would
have to change for the decision to be revisited.

The point of the format is the **Consequences** section. A decision without a
written cost tends to be re-litigated every time someone new encounters it.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-compute-platform.md) | ECS Fargate for the application tier | Accepted |
| [0002](0002-network-segmentation.md) | Three subnet tiers, database isolated by routing | Accepted |
| [0003](0003-terraform-state-backend.md) | S3 backend with native state locking | Accepted |
| [0004](0004-database-credentials.md) | RDS-managed master password | Accepted |
| [0005](0005-deployment-ownership.md) | Pipeline owns the image, Terraform owns the shape | Accepted |
| [0006](0006-schema-management.md) | Schema created at startup, migrations deferred | Accepted, revisit |
| [0007](0007-tls-termination.md) | TLS termination at the ALB, certificate optional | Accepted |
| [0008](0008-supply-chain-pinning.md) | Pin every dependency to an immutable identifier | Accepted |

## Writing a new one

Copy the structure of any existing record: Status, Context, Decision,
Consequences, and Revisit when. Number sequentially. Do not edit an accepted
record to reflect a change of mind -- write a new one that supersedes it, and
mark the old one Superseded. The history is the value.
