#!/bin/bash
# Blue-green app switch (ADR-0015). Pure compose orchestrator: no network,
# no secrets on the command line, safe to run from SSM or locally.
#
#   ./switch.sh deploy     pull, (re)create the idle color, wait for ITS
#                          /ready, reload Caddy if the Caddyfile changed,
#                          then stop the live color. The live color is never
#                          touched before the idle one answers, so a bad
#                          release aborts with zero traffic impact.
#   ./switch.sh reconcile  boot-time cleanup: stop whichever color is not
#                          live (both restart=always, so a reboot starts
#                          both; the `first` policy would otherwise pin blue
#                          forever while green idles).
#
# Env knobs (all optional): COMPOSE_DIR (default /opt/opencode),
# LIVE_FILE (default $COMPOSE_DIR/.live-color), READY_TIMEOUT (poll
# iterations, ~2s each; default 100).
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/opencode}"
LIVE_FILE="${LIVE_FILE:-$COMPOSE_DIR/.live-color}"
READY_TIMEOUT="${READY_TIMEOUT:-100}"

# Reconcile tolerates a missing dir (fresh host, nothing to clean up);
# deploy fails loud instead of operating on the wrong directory.
[ -d "$COMPOSE_DIR" ] || {
  [ "${1:-}" = "reconcile" ] && exit 0
  echo "switch.sh: ERROR: no such directory: $COMPOSE_DIR" >&2
  exit 1
}
cd "$COMPOSE_DIR"

log() { echo "switch.sh: $*"; }
fail() {
  echo "switch.sh: ERROR: $*" >&2
  exit 1
}

live_color() {
  if [ -f "$LIVE_FILE" ]; then
    cat "$LIVE_FILE"
  else
    echo "blue"
  fi
}

idle_color() {
  if [ "$(live_color)" = "blue" ]; then
    echo "green"
  else
    echo "blue"
  fi
}

caddy_running() {
  docker compose ps --status running --services 2>/dev/null | grep -qx "caddy"
}

# Per-color readiness, checked FROM Caddy over the compose network (same
# DNS + path the real traffic takes). Runs inside the caddy container so
# BASIC_AUTH expands there — never on a host command line. Authed GET /
# must come back 2xx: proves the color is up AND the machine-only backend
# password is wired. Unauthed/container-down comes back nonzero.
color_ready() {
  docker compose exec -T caddy \
    sh -c 'wget -q -O /dev/null --header "Authorization: Basic $BASIC_AUTH" http://opencode-'"$1"':4096/' \
    >/dev/null 2>&1
}

wait_for_color() {
  log "waiting for opencode-$1 to answer (up to ~$((READY_TIMEOUT * 2))s)"
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    if color_ready "$1"; then
      log "opencode-$1 is ready"
      return 0
    fi
    sleep 2
  done
  return 1
}

# Aggregate readiness through the public edge: body must be exactly
# "ready" (Caddy masks everything else).
edge_ready() {
  [ "$(curl -sk --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/ready" || true)" = "ready" ]
}

restore_backups() {
  for f in compose.yaml Caddyfile; do
    [ -f "$f.bak" ] && mv -f "$f.bak" "$f"
  done
}

cmd_reconcile() {
  [ -f compose.yaml ] || exit 0
  LIVE="$(live_color)"
  if [ ! -f "$LIVE_FILE" ]; then
    echo "$LIVE" >"$LIVE_FILE"
  fi
  log "live=$LIVE, stopping the idle color (if running)"
  docker compose stop "opencode-$(idle_color)" || true
  log "reconciled"
}

cmd_deploy() {
  [ -f compose.yaml ] && [ -f Caddyfile ] && [ -f app.env ] \
    || fail "run from a compose dir (compose.yaml, Caddyfile, app.env)"
  command -v curl >/dev/null || fail "curl is required for the edge check"
  DOMAIN="$(sed -n 's/^DOMAIN=//p' app.env | head -n 1)"
  [ -n "$DOMAIN" ] || fail "DOMAIN missing from app.env"

  cp -f compose.yaml compose.yaml.bak
  cp -f Caddyfile Caddyfile.bak
  # shellcheck disable=SC2064
  trap "restore_backups" INT TERM

  log "validating compose config"
  docker compose config --quiet \
    || {
      restore_backups
      fail "compose config invalid, nothing touched"
    }

  if caddy_running; then
    log "validating Caddyfile (adapt only, not applied)"
    docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
      || {
        restore_backups
        fail "Caddyfile invalid, nothing touched"
      }
  fi

  log "pulling images (no disruption: nothing restarts on pull)"
  docker compose pull \
    || {
      restore_backups
      fail "pull failed, nothing restarted"
    }

  # One-time migration (ADR-0015): hosts booted before blue-green run a
  # single `opencode` container the new compose no longer manages. The new
  # live color is blue; the legacy container goes only after blue answers.
  PROJ="$(basename "$COMPOSE_DIR")"
  LEGACY="$PROJ-opencode-1"
  MIGRATE=0
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$LEGACY"; then
    MIGRATE=1
    log "legacy container $LEGACY present, migrating to blue-green"
  fi

  if [ "$MIGRATE" = "1" ]; then
    LIVE="legacy"
    IDLE="blue"
  else
    LIVE="$(live_color)"
    IDLE="$(idle_color)"
  fi
  log "live=$LIVE idle=$IDLE"

  log "starting idle color opencode-$IDLE (live keeps serving)"
  docker compose up -d --force-recreate --no-deps "opencode-$IDLE" \
    || fail "could not start opencode-$IDLE, live=$LIVE untouched"

  # Cold edge (dead-host recovery): readiness is probed from inside the
  # caddy container, so a host with no edge running (failed boot, fresh
  # disk) must start it before the idle color can prove itself. Normal
  # deploys skip this: caddy is already up.
  if ! caddy_running; then
    log "edge not running, cold-starting caddy + oauth2-proxy"
    docker compose up -d --no-deps caddy oauth2-proxy \
      || fail "could not start the edge, live=$LIVE untouched"
  fi

  if ! wait_for_color "$IDLE"; then
    log "opencode-$IDLE never became ready, backing out"
    docker compose stop "opencode-$IDLE" || true
    restore_backups
    fail "idle color unhealthy, live=$LIVE still serving"
  fi
  trap - INT TERM

  if caddy_running && ! cmp -s Caddyfile Caddyfile.bak; then
    # Skip the reload when the caddy image itself changed: the recreate
    # below loads the new file in one step (one edge restart, documented
    # in ADR-0015) instead of reload-then-restart.
    CONFIG_IMG="$(docker compose config --images 2>/dev/null | grep -m1 '^caddy ' | awk '{print $2}' || true)"
    RUNNING_IMG="$(docker inspect "$(docker compose ps -q caddy)" --format '{{.Config.Image}}' 2>/dev/null || true)"
    if [ -n "$CONFIG_IMG" ] && [ "$CONFIG_IMG" = "$RUNNING_IMG" ]; then
      log "Caddyfile changed, reloading edge (listeners stay up)"
      docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
        || {
          docker compose stop "opencode-$IDLE" || true
          restore_backups
          docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
          fail "edge reload failed, restored previous Caddyfile"
        }
    else
      log "caddy image changed, skipping reload (recreate below loads the file)"
    fi
  fi

  echo "$IDLE" >"$LIVE_FILE"
  if [ "$MIGRATE" = "1" ]; then
    log "blue answers, removing legacy container $LEGACY"
    docker stop "$LEGACY" >/dev/null || true
    docker rm "$LEGACY" >/dev/null || true
  elif docker compose ps --status running --services 2>/dev/null | grep -qx "opencode-$LIVE"; then
    log "idle answers, stopping previous live opencode-$LIVE (edge fails over)"
    docker compose stop "opencode-$LIVE" || fail "could not stop opencode-$LIVE"
  else
    log "opencode-$LIVE not running (cold edge), nothing to stop"
  fi

  log "converging edge services (no-op unless their images changed)"
  docker compose up -d --no-deps caddy oauth2-proxy

  log "verifying: live color running + edge reports ready"
  docker compose ps --status running --services | grep -qx "opencode-$IDLE" \
    || fail "opencode-$IDLE not running after switch"
  edge_ready || fail "edge /ready is not 'ready' after switch"

  rm -f compose.yaml.bak Caddyfile.bak
  docker compose ps
  log "deploy complete, live=$IDLE"
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  reconcile) cmd_reconcile ;;
  *) fail "usage: $0 {deploy|reconcile}" ;;
esac
