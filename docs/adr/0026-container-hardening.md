# ADR-0026: Container Hardening — cap_drop ALL, Explicit opencode.json Permissions, docker.sock Residual Risk

## Status

Accepted (implements #39)

## Date

2026-09-11

## Context

Issue #39 identified three hardening gaps in the `opencode-blue` /
`opencode-green` backend containers:

1. **docker.sock residual risk not documented.** ADR-0020 decided to cut the
   socket; ADR-0025 confirmed the mounts are absent from `app/compose.yaml`.
   The credential-theft path the socket re-opens if it is ever added back has
   not been written down as a standing residual risk, leaving no durable
   signal for future reviewers.
2. **`cap_drop: [ALL]` missing from backends.** `caddy` and `oauth2-proxy`
   already use `cap_drop: [ALL]` (with selective `cap_add` for the one
   capability each needs). The backend colors did not follow the same pattern:
   they had `cap_add: [SYS_PTRACE]` (required by nono's seccomp network-proxy
   handoff inside Docker) but no explicit capability drop, leaving all Linux
   capabilities from the default set available.
3. **`opencode.json` used `"permission": {"*": "allow"}`.** This wildcard
   grants the agent automatic approval for every tool in every context —
   including `bash` (arbitrary shell commands) and `webfetch` / `websearch`
   (network reads). The nono profile is the true containment boundary, but a
   defence-in-depth posture prefers explicit per-tool grants at the opencode
   layer too, so unexpected tool additions surface as a prompt rather than
   silently succeeding.

## Decision Drivers

- **Must** record the docker.sock credential-theft risk explicitly so future
  PRs that re-mount the socket trigger a conscious override, not a silent
  regression.
- **Must** match the `cap_drop: [ALL]` + selective `cap_add` pattern already
  used by every other service in the compose stack.
- **Must** replace `"*": "allow"` with explicit, narrower grants that require
  confirmation (`ask`) for high-consequence tools (`bash`, `webfetch`,
  `websearch`, `external_directory`).
- **Should not** break the agent's normal development workflow (read, edit,
  glob, grep, list, task, todowrite must remain auto-allowed).

## Decision

### 1. docker.sock — record residual risk (no code change needed)

`docker.sock` is already absent from the backend color mounts. This ADR
documents the permanent residual risk: if `docker.sock` is ever re-mounted
into a backend container (even read-only), the agent gains access to the Docker
daemon running as root on the host. The daemon can launch privileged containers
that escape the nono Landlock boundary entirely, mount the host filesystem, and
exfiltrate any credential reachable by root. **The socket must never be
re-mounted without a separate, reviewed ADR.**

### 2. `cap_drop: [ALL]` added to opencode-blue and opencode-green

Both backend colors now carry:

```yaml
cap_drop:
  - ALL
cap_add:
  - SYS_PTRACE
```

This is identical to the pattern `caddy` uses (`cap_drop: [ALL]` +
`cap_add: [NET_BIND_SERVICE]`). The net effect is that only `SYS_PTRACE` is
present; all other Linux capabilities (e.g. `NET_RAW`, `SYS_ADMIN`, `SETUID`,
`CHOWN`) are stripped. `no-new-privileges:true` is retained alongside.

`read_only: true` was evaluated and deferred: the containers write to `/root`
(workspace volume) and `/root/.local/share/opencode` (data volume), and the
entrypoint writes `/root/.git-credentials` before the sandbox applies. Adding
`read_only: true` would require `tmpfs` mounts for every writable path
(including temporary shell files written by nono's network-proxy handoff),
introducing fragile path enumeration. Follow-up issue to revisit when the
entrypoint stabilises.

Running as a non-root `user:` was also deferred: the workspace volume is owned
by `root` and the nono profile references `/root` paths. Changing ownership
requires a volume migration or an init container. Follow-up issue.

### 3. opencode.json — explicit permission grants

`"permission": {"*": "allow"}` is replaced with per-tool grants:

| Tool | Grant | Rationale |
|---|---|---|
| `read` | `allow` | Core read tool; always needed |
| `edit` | `allow` | Core write tool; always needed |
| `glob` | `allow` | File discovery; low risk |
| `grep` | `allow` | Content search; low risk |
| `list` | `allow` | Directory listing; low risk |
| `bash` | `ask` | Arbitrary shell; high consequence — prompt before each run |
| `task` | `allow` | Subagent delegation; needed for complex tasks |
| `external_directory` | `ask` | Cross-repo access; prompt before granting |
| `todowrite` | `allow` | Task tracking; low risk |
| `webfetch` | `ask` | Network read; prompt (nono filters egress, belt-and-suspenders) |
| `websearch` | `ask` | Network read; same rationale as webfetch |

Tools not listed (`question`, `lsp`, `doom_loop`, `skill`) inherit the opencode
default (which is `ask` for most tools, keeping the posture conservative).
`"*": "allow"` is not used anywhere; any new tool added to opencode in a future
version will require an explicit grant or will prompt, rather than silently
auto-allowing.

## Rationale

The changes together close the capability over-permission gap with a single
YAML addition, align the backend services with the established `caddy` pattern,
and replace a blanket wildcard permission with a least-privilege grant list that
is both schema-validated (`https://opencode.ai/config.json`) and easy to audit.
The docker.sock risk documentation converts a silent tribal-knowledge constraint
into a reviewable contract.

## Consequences

### Positive

- Backend containers no longer hold the full default Linux capability set;
  only `SYS_PTRACE` is present.
- Agent `bash` tool invocations now require confirmation in the UI — operators
  see what shell commands the agent wants to run before they execute.
- Future unknown tools will prompt rather than auto-execute.
- The docker.sock credential-theft path is formally recorded; any re-addition
  requires an explicit ADR override.

### Negative

- `bash` now prompts on every invocation; sessions with many `bash` calls
  will require more operator interaction. Mitigation: the nono sandbox is the
  real enforcement layer — operators may choose to loosen `bash` to `allow`
  at the project level if the workflow requires it.
- `read_only` and non-root `user:` remain deferred; the container still runs
  as root with a writable root filesystem outside the named volumes.

## Implementation Notes

- Files changed: `app/compose.yaml` (both backend colors), `app/opencode.json`,
  `docs/FEATURES.md`.
- `read_only: true` follow-up: open a new issue once the entrypoint is
  stabilised and all writable paths are catalogued.
- Non-root `user:` follow-up: requires a volume-ownership migration plan.

## Related Decisions

- ADR-0020 (spike verdict: adopt pilot, docker.sock cut — this ADR records
  the residual risk explicitly)
- ADR-0025 (nono sandbox pilot: confirms docker.sock mounts are absent)
- ADR-0007 (compose stack this change is applied to)
- ADR-0003 (supply-chain hygiene, defence-in-depth context)

## References

- Issue #39 (this work)
- https://opencode.ai/config.json (PermissionConfig schema)
- Docker Compose `cap_drop` / `cap_add` docs: https://docs.docker.com/compose/compose-file/05-services/#cap_drop
- Linux capabilities man page: https://man7.org/linux/man-pages/man7/capabilities.7.html
