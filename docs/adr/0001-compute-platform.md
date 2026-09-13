# 0001 - ECS Fargate for the application tier

**Status:** Accepted

## Context

The platform runs one stateless HTTP service backed by PostgreSQL. Three hosting
options were realistic: EKS, ECS on Fargate, or EC2 instances behind an Auto
Scaling Group.

The service has no need for custom scheduling, sidecar injection, or
cluster-local service discovery. It has a strong need to be operated by a small
team without a dedicated platform function.

## Decision

ECS Fargate, with tasks in private subnets behind an Application Load Balancer.

EKS was rejected because it introduces node groups, the cluster autoscaler,
IRSA, an ingress controller, and a Kubernetes minor-version upgrade every few
months. That is a standing operational commitment, and none of it is work this
service requires.

EC2 was rejected because it makes the team responsible for AMIs, OS patching,
and a deployment mechanism of its own.

## Consequences

Gained:

- No hosts to patch. The runtime is AWS's responsibility.
- Per-task billing, so idle capacity is cheap and scale-out is granular.
- The ECS deployment circuit breaker provides automatic rollback with no
  pipeline code.
- Fargate Spot is a one-line capacity provider change, which is what makes
  non-production compute inexpensive.

Given up:

- No daemonset-equivalent. A node-level agent (for example a log shipper or an
  APM collector) has to become a sidecar on every task instead.
- No control over placement or bin-packing.
- Higher per-vCPU price than EC2 at sustained high utilisation.

## Revisit when

The platform runs enough services that per-service ALBs and task definitions
become the bottleneck, or when sustained utilisation is high enough that the
Fargate premium exceeds the cost of operating nodes. Roughly: more than a dozen
services, or steady-state utilisation above about 60 percent across the fleet.
