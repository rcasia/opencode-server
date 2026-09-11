# ADR-0022: Automatic recovery of in-flight sessions (spike verdict)

## Status

Accepted (spike verdict for #28: adopt constrained recovery, reject
blind resubmission)

## Date

2026-09-11

## Context

Blue/green deploys (ADR-0015) are zero-downtime for the public
endpoint but not for in-flight agent work: when the live color (or
the host) is replaced mid-prompt, the process handling the prompt
dies and the client stream breaks. Issue #28 asked whether the new
instance can detect and resume/retrigger the interrupted execution
using OpenCode's own session/message APIs and persisted state, with
no generic job queue. No terraform/compose changes in this spike; no
PoC was built (no Docker daemon in this lane — the probe must be
proven against a live server as follow-up work).

References below are to the pinned server (`ghcr.io/anomalyco/opencode:1.18.30`,
`opencode web` on :4096) and the documented `serve`/`web` HTTP API
(same server; spec at `http://<host>:4096/doc`).

## Evidence gathered (answers to the issue questions)

- **What happens on termination mid-prompt.** The run loop is
  in-memory in the killed process. SIGTERM (30 s grace per
  `stop_grace_period`) then SIGKILL severs the provider stream and
  the client SSE/HTTP stream. Nothing resumes on boot: a fresh
  process owns no runs.
- **Where state is persisted.** Incrementally, per message/part, to
  the data dir (`~/.local/share/opencode`, i.e.
  `/root/.local/share/opencode` in the container): file-JSON
  (`storage/session/<project>/<id>.json`,
  `storage/message/<session>/<msg>.json`,
  `storage/part/<msg>/<part>.json`, plus `session_diff/`, `todo/`)
  in the 1.x line, SQLite (`opencode.db`) in newer builds. Either
  way every completed step is already on disk when the kill lands.
- **Can the new instance retrieve the previous session.** Yes.
  Both colors mount the same `opencode-data` and
  `opencode-workspace` volumes (`app/compose.yaml`), which live on
  the persistent EBS data disk (ADR-0008) — so history survives
  color switches AND host replacement. `GET /session/:id` +
  `GET /session/:id/message` return it.
- **Relevant endpoints.** `GET /session`, `GET /session/status`
  (per-session run state on THIS process), `GET /session/:id`,
  `GET /session/:id/message` (+ `/:messageID`), `POST
  /session/:id/message` (send + wait), `POST
  /session/:id/prompt_async` (204, no wait), `POST
  /session/:id/abort`, `GET /session/:id/diff` (file diffs),
  `POST /session/:id/revert`, `POST /session/:id/fork`.
- **Can interruption be detected.** Heuristically, yes: last message
  is user-role with no completing assistant message (no step-finish
  parts) AND `GET /session/status` reports the session idle on the
  new process (status only reflects runs owned by the live
  process). Correlating `session.time.updated` with the deploy
  timestamp removes most ambiguity.
- **Can the prompt be retrieved and resubmitted.** Yes: last user
  message from history, resubmitted via `POST
  /session/:id/message` or `prompt_async`.
- **Can the four states be distinguished.** Running = status shows
  an active run (only while the owning process lives). Completed =
  assistant message with step-finish/error parts. Interrupted =
  dangling user message + idle status after a deploy. Conn-lost-only
  (run continued server-side) is possible only when the process
  survives; after a replacement the run is dead too, so conn-lost
  collapses into interrupted.
- **Correlation/idempotency IDs.** Message IDs (`msg_*`) correlate;
  but prompt submission carries NO idempotency key — every
  resubmission starts a NEW run. Exactly-once is not available.
- **Completed-but-conn-lost.** Safe: the response is persisted and
  re-fetchable from history; no resubmission needed.
- **Duplicate-execution risk (the load-bearing one).** Tool
  side-effects applied before the kill (file edits, commits,
  shell/deploy actions) are NOT undone by resubmission. A naive
  auto-retry redoes real-world actions. This is the fact that kills
  blind automatic recovery.

## Considered Options

### A. Blind automatic resubmission on boot (rejected)

New instance detects dangling prompts and re-fires them.

- **Rejected**: re-executes unknown partial side-effects with no
  idempotency. File writes aside, a retried "deploy" or "push"
  prompt can double-apply outside the repo. No API primitive makes
  this safe.

### B. Constrained recovery: drain + detect + diff-gated retry (chosen)

Three cheap pieces, no queue:

1. **Drain in `switch.sh`.** Before stopping the live color, poll
   `GET /session/status`; delay the stop while a run is active up
   to a bound (e.g. 5 min), then proceed. Most deploys stop killing
   runs at all.
2. **Detect + mark.** After a switch/replacement, probe for
   dangling user messages (idle status + no completing assistant
   message + updated-at near the deploy) and surface them (log +
   session title/marker), so the operator sees "interrupted by
   deploy" instead of silence.
3. **Diff-gated retry only.** Retrigger automatically ONLY when
   `GET /session/:id/diff` is empty (no file side-effects yet);
   otherwise leave the marked session for human retry (or
   `revert`/`fork` first). Non-file side-effects (shell, pushes)
   can still predate the kill — hence gate, not guarantee.

- **Pros**: implements entirely with existing APIs + volumes;
  drain removes the common case; diff-gate bounds the dangerous
  case; no new infrastructure.
- **Cons**: heuristic detection (edge cases: kill between user
  write and run start looks identical — correctly treated as
  interrupted); diff-gate covers file effects only; human retry
  remains for the rest.

### C. External queue (SQS/scheduler) for exactly-once (rejected)

- **Rejected**: out of scope per the issue, contradicts
  cheap-by-design, and cannot fix non-idempotent agent tools
  anyway — the queue would be ceremony around the same heuristic.

## Decision

Adopt option B: bounded drain in the deploy path plus
detect-and-mark with diff-gated retry. Reject blind
auto-resubmission (option A) and any job-queue machinery
(option C).

## Rationale

Detection and safe resubmission primitives exist today (shared
volumes, session/message/diff/status APIs), so the feasible subset
should be built. Full automation is unsafe because the API offers
no idempotency and partial tool effects are invisible to the
retry — the gate (drain first, diff-check second, human otherwise)
is the whole design.

## Consequences

### Positive

- Deploys stop interrupting runs in the common case (drain).
- Interruptions that still happen are visible and cheaply
  resumable instead of silent.

### Negative

- `switch.sh` deploys can take up to the drain bound longer.
- Non-file side-effects stay human-gated (accepted; recorded here).

## Implementation Notes (follow-ups, not this commit)

1. New issue: drain bound + detect/mark + diff-gated retry probe
   against a live server (prove the dangling-message heuristic and
   the status-poll loop; record endpoint/version drift for the
   1.18.30 pin).
2. On landing: FEATURES.md update (rule 10) — recovery behavior is
   user-visible.

## Related Decisions

- ADR-0015 (blue-green deploys this plugs into), ADR-0008 (volumes
  that make history survive), ADR-0007 (compose stack)

## References

- Issue #28 (spike); `app/compose.yaml` (shared volumes, 30 s grace);
  `app/switch.sh` (stop path); https://opencode.ai/docs/server
  (endpoint reference); spec at `http://<host>:4096/doc` on the
  pinned image
