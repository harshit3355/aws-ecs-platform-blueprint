# 0002 - Three subnet tiers, database isolated by routing

**Status:** Accepted

## Context

The conventional two-tier layout puts the load balancer in public subnets and
everything else in private subnets. That leaves the database sharing a route
table with the application, which means the database has a working path to the
internet through the NAT gateway.

Nothing uses that path. It exists because of where the database happens to sit.

## Decision

Three tiers per availability zone:

| Tier | Route to internet | Contains |
|---|---|---|
| Public | Internet gateway | ALB, NAT gateway |
| Private | Via NAT | ECS tasks |
| Database | **None** | RDS |

The database route table has no internet gateway route and no NAT route. Not a
denied route -- an absent one.

## Consequences

Gained:

- "The database cannot initiate outbound connections" is a property of the
  route table, enforced by the network, rather than of a security group rule
  that someone can widen under time pressure during an incident.
- Two independent controls say the same thing: the RDS security group also has
  no egress rules at all. Either alone would be sufficient; both together mean
  a single mistake is not enough.
- The tiers are addressable as a unit, so a future data store lands in the
  right place by default.

Given up:

- Anything in the database tier that needs to reach an AWS API needs a VPC
  endpoint. Today nothing does; RDS-managed password rotation runs inside the
  service, not from the instance.
- A third set of subnets and route tables to reason about.

## Revisit when

Something in the data tier legitimately needs outbound access -- for example a
self-managed database performing its own backups to a third party. The answer
then is a VPC endpoint, not a NAT route.
