# ADR-0016: Enforce IMDSv2 on the coding server

## Status

Accepted

## Date

2026-09-11

## Context

opencode runs arbitrary agent-generated code with `docker.sock`
mounted, i.e. container code is effectively root on the host. IMDSv1
answers unauthenticated requests, so an SSRF-style trick can steal
instance credentials; IMDSv2 requires a session token instead.

## Decision

Set `metadata_options { http_endpoint = "enabled", http_tokens =
"required", http_put_response_hop_limit = 1 }` on
`aws_instance.server`. Containers never call IMDS (AWS access flows
through the instance role), so nothing needs the old behavior.

## Consequences

- IMDSv1 credential theft via SSRF is closed; hop limit 1 keeps
  credentials off the container network path.
- Changing these options replaces the instance (cattle, expected).
- No cost change.
