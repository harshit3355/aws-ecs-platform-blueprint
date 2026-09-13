# 0008 - Pin every dependency to an immutable identifier

**Status:** Accepted

## Context

Three classes of dependency enter this repository, and each has a mutable
default that most projects accept without noticing:

| Dependency | Common form | Mutable? |
|---|---|---|
| GitHub Actions | `uses: org/action@v4` | Yes -- a tag is a movable ref |
| Container base image | `FROM python:3.14-slim` | Yes -- tags are republished |
| Python packages | `fastapi>=0.100` | Yes -- resolves differently over time |

The risk is not theoretical. In March 2026 an attacker retargeted 75 tags of a
widely used security-scanning action at a credential stealer. Every workflow
pinned to a tag picked it up automatically on its next run, and the payload
exfiltrated CI secrets. The irony that the compromised action was a vulnerability
scanner is worth sitting with: the dependency most trusted to find problems was
the one that introduced them.

## Decision

Pin everything to something that cannot be repointed.

- **Actions** -- full 40-character commit SHA, with the human-readable version
  in a trailing comment so the intent stays legible:
  ```yaml
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  ```
- **Base image** -- digest, with the tag retained for readability:
  ```dockerfile
  ARG PYTHON_IMAGE=python:3.14.7-slim-trixie@sha256:cad9a2c871761c...
  ```
- **Python packages** -- exact `==` pins, never ranges.
- **Terraform modules and providers** -- exact module versions, `~>` on the
  provider so patch releases are picked up but a major is not.

## Consequences

Gained:

- The bytes that passed CI are the bytes that reach production. That is what
  makes a vulnerability scan a meaningful gate rather than a snapshot of
  something else.
- A scanner finding maps to one specific version, so it is actionable.
- A compromised upstream tag has no effect here until someone deliberately
  updates the pin and reviews the diff.

Given up:

- Updates do not arrive on their own. Without automation the pins go stale,
  which trades a supply-chain risk for a patching risk.
- SHAs are unreadable, which is why every pin carries a version comment.

## Mitigation for the cost

Dependabot or Renovate, configured to raise pull requests that bump pins. That
keeps the update path open while every change still passes through review and
the full CI gate. This is the first thing to add and is listed as such in the
README.

## Revisit when

Never for the principle. The mechanism changes if a stronger option becomes
available -- signed action releases with verification in the runner, or image
signature verification enforced at the ECS pull.
