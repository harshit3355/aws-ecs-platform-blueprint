# 0007 - TLS terminated at the load balancer, certificate optional

**Status:** Accepted

## Context

TLS can terminate at the load balancer or end-to-end at the task. Terminating
at the ALB is standard: certificate lifecycle is managed by ACM, renewal is
automatic, and the tasks serve plain HTTP inside the VPC.

Separately, a certificate requires a validated domain. Environments that have
no domain registered cannot have one, and the configuration must still be
applicable in that state rather than failing to plan.

## Decision

TLS terminates at the ALB. `certificate_arn` is a variable defaulting to `null`.

- With a certificate: an HTTPS listener on 443 using `ELBSecurityPolicy-TLS13-1-2-2021-06`, and port 80 returns a 301 to it.
- Without: port 80 forwards directly, and the README states this plainly as a
  known gap rather than leaving a reader to infer that HTTPS exists.

Traffic between the ALB and the tasks is plain HTTP inside private subnets.
Traffic between the tasks and RDS is *not* optional: `rds.force_ssl = 1` makes
the database reject plaintext connections, and the service connects with
`sslmode=require`.

## Consequences

Gained:

- One certificate to manage, renewed by ACM without intervention.
- The configuration is valid and deployable in an environment with no domain.
- The database leg is encrypted regardless, which is the leg carrying
  credentials and customer data across an AZ boundary.

Given up:

- The ALB-to-task hop is unencrypted. It stays inside the VPC, between two
  security groups that admit only each other, but it is not encrypted in
  transit and should be stated rather than assumed.
- An HTTP-only environment is genuinely insecure for anything real. This is
  acceptable only where no real traffic exists.

## Revisit when

A compliance regime requires encryption in transit everywhere, or the service
handles regulated data. The change is an HTTPS target group with a certificate
in the task, or a service mesh providing mTLS.
