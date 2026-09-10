# ADR-0007: Containerized Deployment via Compose

## Status

Accepted

## Date

2026-09-10

## Context

ADR-0001 installed Caddy and opencode on the host via `user_data`
(`dnf`, `curl | bash`, COPR repo). That boot takes ~10 minutes on a
`t3.micro`, can fail partway (aborting everything after it), and is
untestable locally — Moto never boots a machine, so the first execution
was on prod, where a silent failure left ports 80/443 closed with no
diagnostics available from the pipeline.

## Decision Drivers

- **Must make boot deterministic** — no package installs at boot time.
- **Must be testable locally** — the exact prod artifact must run on a laptop.
- **Should keep versions pinned and bumpable** — same supply-chain rules as
  everything else (ADR-0003).
- **Should shrink `user_data`** to near-unbreakable: Docker + files + up.

## Considered Options

### Option 1: Compose stack from pinned upstream images (chosen)

`app/compose.yaml` runs `ghcr.io/anomalyco/opencode` (`web --hostname
0.0.0.0`) behind official `caddy`, both pinned `tag@digest` with Dependabot
(`docker` ecosystem) proposing bumps. `app/Caddyfile` and `app/app.env`
(one env file for both services: `DOMAIN`, `OPENCODE_SERVER_PASSWORD`)
are committed; `user_data` only installs Docker, writes the files, fetches
the password from SSM, and runs `docker compose up -d`.

- **Pros**: byte-identical services locally and on prod (`make test-boot`
  exercises the full TLS → proxy → auth chain); boot in seconds; Caddy and
  opencode upgrade as Dependabot diffs.
- **Cons**: new build-less dependency on two upstream images (accepted:
  digest-pinned, public, no credentials); Docker-in-Docker socket mount for
  the agent (accepted: it's a coding server, the agent needs Docker).

### Option 2: Keep host installs, add container smoke test (rejected)

Tests the procedure in Docker but ships a different thing than tested —
the divergence that caused this ADR stays.

### Option 3: Bake a custom AMI with Packer (rejected)

Deterministic, but a whole image pipeline (build, version, GC) for one
box — heavier than the problem warrants while compose solves it.

## Decision

We will ship **Caddy + opencode as a compose stack of digest-pinned
upstream images**, with `user_data` reduced to Docker install, file
layout, SSM password fetch, and `compose up`. The `opencode_port`
variable is removed (4096 hardcoded in `app/` — one fewer knob to
mismatch). Host keeps Docker, rsyslog, and the CloudWatch agent (Caddy
logs reach the host via bind mount, so ADR-0006 keeps working).

## Rationale

It converts the least-tested part of the system (a 10-minute shell
bootstrap) into the most-tested (the literal prod compose file running
locally), while deleting code instead of adding it.

## Consequences

### Positive

- `make test-boot`: full chain on a laptop in ~2 minutes, no emulation of installs.
- Boot failures become image-pull failures: loud, early, retryable.
- `user_data` changes rarely now; instance replacements become rare.

### Negative

- Upstream image moves (`sst` → `anomalyco` rename already happened once)
  would break pulls — mitigation: digest pins fail closed, Dependabot
  surfaces new tags, and the rename precedent is recorded here.
- `latest` is unpinned by nature — we pin `1.18.30@sha256:…` instead and
  let Dependabot propose the next version.
- Local test still can't prove Let's Encrypt issuance (needs public IP).

## Implementation Notes

- `app/compose.yaml`, `app/Caddyfile`, `app/app.env.example` committed;
  `app/app.env` gitignored (dummy locally, SSM-backed on prod).
- `user_data.sh` renders the three files via `templatefile` + shell
  heredoc; `{$DOMAIN}` is Terraform-safe (no `${` sequence).
- `scripts/test-boot.sh` rewritten around compose; `make test-boot` runs it.
- `dependabot.yml` gains the `docker` ecosystem for `/app`.
- `.github` paths-filter: `app/**` counts as infra (redeploys prod).

## Amendment (2026-09-10, same day)

The Dependabot `docker` ecosystem does **not** read compose files — its
updater aborts with "No Dockerfiles nor Kubernetes YAML found". The
`docker` entry was removed; `app/compose.yaml` pins are bumped by hand
(process in README). Everything else in this record stands.

## Amendment 2 (2026-09-10, same day)

Correction to the above: Dependabot has a **separate `docker-compose`
ecosystem** for compose files — the correct entry (now in
`dependabot.yml`), same cooldown policy. Manual bumping stays as fallback.

## Related Decisions

- ADR-0001 (Caddy + localhost backend — kept, repackaged)
- ADR-0003 (digest pins extend SHA-pinning to images)
- ADR-0004 (password still from SSM, now via env file)
- ADR-0006 (log bind mount preserves alerting)

## References

- [opencode Server docs](https://opencode.ai/docs/server/)
- [Caddy Docker Hub](https://hub.docker.com/_/caddy)
