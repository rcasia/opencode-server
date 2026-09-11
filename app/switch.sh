#!/bin/bash
# Blue-green app switch (ADR-0015) with constrained session recovery
# (ADR-0022, issue #32). Pure compose orchestrator: no network, no
# secrets on the command line, safe to run from SSM or locally.
#
#   ./switch.sh deploy     pull, (re)create the idle color, wait for ITS
#                          /ready, reload Caddy if the Caddyfile changed,
#                          drain the live color (bounded wait while
#                          GET /session/status reports busy), then stop
#                          the live color. The live color is never
#                          touched before the idle one answers, so a bad
#                          release aborts with zero traffic impact. After
#                          the switch, probe the new live color for
#                          sessions interrupted by the deploy and
#                          diff-gate their retry (empty diff only).
#   ./switch.sh reconcile  boot-time cleanup: stop whichever color is not
#                          live (both restart=always, so a reboot starts
#                          both; the `first` policy would otherwise pin blue
#                          forever while green idles). Best-effort recovery
#                          probe on the live color (host replacement also
#                          kills runs).
#   ./switch.sh recover [color]
#                          best-effort recovery probe only (no stop/start):
#                          detect dangling user messages on <color>
#                          (default: live color), mark them
#                          "[interrupted-by-deploy]", and auto-retrigger
#                          via prompt_async only when GET /session/:id/diff
#                          is empty. Never fails: logs and exits 0.
#
# Recovery endpoints verified against the pinned server
# (ghcr.io/anomalyco/opencode:1.18.30, `opencode web` on :4096) on
# 2026-09-11: GET /session, GET /session/status ({sid:{type:
# idle|busy|retry}}; idle/absent = no run on this process),
# GET /session/:id (.time.updated ms, .title), GET
# /session/:id/message (last info.role user + no trailing assistant =
# dangling), GET /session/:id/diff ([] = no file side-effects),
# PATCH /session/:id {title} (mark), POST /session/:id/prompt_async
# (retry, 204 no wait). No drift vs ADR-0022. Blind resubmission
# stays rejected: every retry is a new run (no idempotency key) and
# non-file effects (shell, pushes) are invisible to the diff gate.
#
# Env knobs (all optional): COMPOSE_DIR (default /opt/opencode),
# LIVE_FILE (default $COMPOSE_DIR/.live-color), READY_TIMEOUT (poll
# iterations, ~2s each; default 100), DRAIN_TIMEOUT (drain poll
# iterations, ~2s each; default 150 = ~5 min bound, then proceed),
# RECOVERY_WINDOW (seconds before deploy start in which a session
# update counts as "near the deploy"; default 1800 = 30 min).
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/opencode}"
LIVE_FILE="${LIVE_FILE:-$COMPOSE_DIR/.live-color}"
READY_TIMEOUT="${READY_TIMEOUT:-100}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-150}"
RECOVERY_WINDOW="${RECOVERY_WINDOW:-1800}"
RECOVERY_PREFIX="[interrupted-by-deploy]"

# Sanitize numeric knobs (a garbage env value must never abort a deploy).
case "$READY_TIMEOUT" in '' | *[!0-9]*) READY_TIMEOUT=100 ;; esac
case "$DRAIN_TIMEOUT" in '' | *[!0-9]*) DRAIN_TIMEOUT=150 ;; esac
case "$RECOVERY_WINDOW" in '' | *[!0-9]*) RECOVERY_WINDOW=1800 ;; esac

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

edge_ready() {
  [ "$(curl -sk --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/ready" || true)" = "ready" ]
}

restore_backups() {
  for f in compose.yaml Caddyfile; do
    [ -f "$f.bak" ] && mv -f "$f.bak" "$f"
  done
}

# Backend API via the edge (caddy carries curl + $BASIC_AUTH; the
# backends are not published to the host). All helpers fail-open:
# callers decide whether a failure aborts (readiness) or only logs
# (drain/recovery must never block a deploy on a monitoring miss).
backend_get() {
  docker compose exec -T caddy \
    sh -c 'curl -sf --max-time 10 -H "Authorization: Basic $BASIC_AUTH" http://opencode-'"$1"':4096'"$2" 2>/dev/null
}

# $1=color $2=path $3=base64(JSON body) $4=METHOD(POST|PATCH)
backend_write() {
  docker compose exec -T caddy \
    sh -c 'curl -sf --max-time 30 -X '"$4"' -H "Authorization: Basic $BASIC_AUTH" -H "Content-Type: application/json" --data "$(printf %s '"'$3'"' | base64 -d)" http://opencode-'"$1"':4096'"$2"' >/dev/null 2>&1'
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Bounded drain (ADR-0022 part 1): while GET /session/status on the
# live color reports any busy/retry run, delay its stop up to
# DRAIN_TIMEOUT polls (~2s each, default ~5 min), then proceed
# regardless. Never fails: unreachable status skips the wait.
drain_live() {
  command -v jq >/dev/null 2>&1 || {
    log "drain: jq missing, skipping drain wait for opencode-$1"
    return 0
  }
  caddy_running || {
    log "drain: edge not running, nothing to drain on opencode-$1"
    return 0
  }
  log "drain: waiting for runs on opencode-$1 to finish (up to ~$((DRAIN_TIMEOUT * 2))s)"
  for _ in $(seq 1 "$DRAIN_TIMEOUT"); do
    STATUS="$(backend_get "$1" "/session/status" || true)"
    [ -n "$STATUS" ] || {
      log "drain: status unreachable, proceeding (fail-open)"
      return 0
    }
    if printf '%s' "$STATUS" | jq -e '[.[] | select(.type == "busy" or .type == "retry")] | length > 0' >/dev/null 2>&1; then
      sleep 2
      continue
    fi
    log "drain: opencode-$1 idle, proceeding"
    return 0
  done
  log "drain: bound reached, proceeding even though opencode-$1 may still be busy"
  return 0
}

# Constrained recovery probe (ADR-0022 parts 2+3): detect dangling
# user messages on <color> (idle status + last message user-role with
# no trailing assistant + updated-at within RECOVERY_WINDOW of
# <deploy_start_epoch>), mark them via PATCH title, and retrigger via
# prompt_async ONLY when GET /session/:id/diff is empty. Best-effort:
# every backend miss logs and continues; this function always exits 0
# so a monitoring miss never fails a deploy or boot.
recover_color() {
  set +e
  COLOR="$1"
  DEPLOY_START="${2:-$(date +%s)}"
  command -v jq >/dev/null 2>&1 || {
    log "recover: jq missing, skipping recovery probe on opencode-$COLOR"
    set -e
    return 0
  }
  caddy_running || {
    log "recover: edge not running, skipping recovery probe on opencode-$COLOR"
    set -e
    return 0
  }
  color_ready "$COLOR" || {
    log "recover: opencode-$COLOR not answering, skipping recovery probe"
    set -e
    return 0
  }
  SESSIONS="$(backend_get "$COLOR" "/session" || true)"
  [ -n "$SESSIONS" ] || {
    log "recover: session list unreachable on opencode-$COLOR, skipping"
    set -e
    return 0
  }
  IDS="$(printf '%s' "$SESSIONS" | jq -r '.[].id' 2>/dev/null || true)"
  [ -n "$IDS" ] || {
    log "recover: no sessions on opencode-$COLOR, nothing to do"
    set -e
    return 0
  }
  STATUS_ALL="$(backend_get "$COLOR" "/session/status" || echo '{}')"
  FOUND=0
  RETRIED=0
  # IDS is a newline-separated session list, word-splitting intended.
  # shellcheck disable=SC2086
  for SID in $IDS; do
    SJSON="$(backend_get "$COLOR" "/session/$SID" || true)"
    [ -n "$SJSON" ] || {
      log "recover: $SID unreachable, skipping"
      continue
    }
    UPDATED_MS="$(printf '%s' "$SJSON" | jq -r '.time.updated // 0' 2>/dev/null || echo 0)"
    TITLE="$(printf '%s' "$SJSON" | jq -r '.title // ""' 2>/dev/null || echo "")"
    case "$UPDATED_MS" in '' | *[!0-9]*) UPDATED_MS=0 ;; esac
    UPDATED_SEC=$((UPDATED_MS / 1000))
    if [ "$UPDATED_SEC" -lt $((DEPLOY_START - RECOVERY_WINDOW)) ]; then
      continue
    fi
    STYPE="$(printf '%s' "$STATUS_ALL" | jq -r --arg s "$SID" '.[$s].type // "idle"' 2>/dev/null || echo idle)"
    case "$STYPE" in busy | retry)
      log "recover: $SID still $STYPE, skipping (not interrupted)"
      continue
      ;;
    esac
    MJSON="$(backend_get "$COLOR" "/session/$SID/message" || true)"
    [ -n "$MJSON" ] || {
      log "recover: $SID messages unreachable, skipping"
      continue
    }
    MLEN="$(printf '%s' "$MJSON" | jq -r 'length' 2>/dev/null || echo 0)"
    [ "$MLEN" -gt 0 ] 2>/dev/null || continue
    LAST_ROLE="$(printf '%s' "$MJSON" | jq -r '.[-1].info.role // ""' 2>/dev/null || echo "")"
    [ "$LAST_ROLE" = "user" ] || continue
    FOUND=$((FOUND + 1))
    log "recover: $SID has a dangling user message (idle, updated near deploy)"
    case "$TITLE" in
      "$RECOVERY_PREFIX"*)
        log "recover: $SID already marked, skipping re-mark"
        ;;
      *)
        NEWTITLE="$(printf '%s %s' "$RECOVERY_PREFIX" "$TITLE" | cut -c1-200)"
        PATCH_BODY="$(jq -n --arg t "$NEWTITLE" '{title: $t}')"
        if backend_write "$COLOR" "/session/$SID" "$(b64 "$PATCH_BODY")" "PATCH"; then
          log "recover: $SID marked '$RECOVERY_PREFIX'"
        else
          log "recover: WARNING: could not mark $SID (continuing)"
        fi
        ;;
    esac
    DIFF="$(backend_get "$COLOR" "/session/$SID/diff" || echo 'unknown')"
    if [ "$DIFF" = "unknown" ]; then
      log "recover: WARNING: $SID diff unreachable, leaving for human retry"
      continue
    fi
    if ! printf '%s' "$DIFF" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
      log "recover: $SID has non-empty diff, leaving marked for human retry (revert/fork first)"
      continue
    fi
    AGENT="$(printf '%s' "$MJSON" | jq -r '.[-1].info.agent // "build"' 2>/dev/null || echo build)"
    MODEL="$(printf '%s' "$MJSON" | jq -c '.[-1].info.model // empty' 2>/dev/null || true)"
    PARTS="$(printf '%s' "$MJSON" | jq -c '[.[-1].parts[] | select(.type == "text") | {type, text}]' 2>/dev/null || echo '[]')"
    [ -n "$MODEL" ] || {
      log "recover: WARNING: $SID has no model, leaving marked for human retry"
      continue
    }
    if [ "$(printf '%s' "$PARTS" | jq -r 'length' 2>/dev/null || echo 0)" = "0" ]; then
      log "recover: WARNING: $SID has no text parts, leaving marked for human retry"
      continue
    fi
    RETRY_BODY="$(jq -n --argjson p "$PARTS" --argjson m "$MODEL" --arg a "$AGENT" '{agent: $a, model: $m, parts: $p}')"
    if backend_write "$COLOR" "/session/$SID/prompt_async" "$(b64 "$RETRY_BODY")" "POST"; then
      RETRIED=$((RETRIED + 1))
      log "recover: $SID retriggered via prompt_async (diff was empty)"
    else
      log "recover: WARNING: $SID auto-retry failed, leaving marked for human retry"
    fi
  done
  log "recover: probe complete on opencode-$COLOR (flagged=$FOUND, retried=$RETRIED)"
  set -e
  return 0
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
  recover_color "$LIVE" "$(date +%s)" || true
}

cmd_recover() {
  COLOR="${2:-$(live_color)}"
  case "$COLOR" in blue | green) ;; *) fail "usage: $0 recover [blue|green]" ;; esac
  recover_color "$COLOR" "$(date +%s)" || true
}

cmd_deploy() {
  [ -f compose.yaml ] && [ -f Caddyfile ] && [ -f app.env ] \
    || fail "run from a compose dir (compose.yaml, Caddyfile, app.env)"
  command -v curl >/dev/null || fail "curl is required for the edge check"
  DOMAIN="$(sed -n 's/^DOMAIN=//p' app.env | head -n 1)"
  [ -n "$DOMAIN" ] || fail "DOMAIN missing from app.env"
  DEPLOY_START="$(date +%s)"

  cp -f compose.yaml compose.yaml.bak
  cp -f Caddyfile Caddyfile.bak
  # shellcheck disable=SC2064
  trap "restore_backups" INT TERM

  log "validating compose config"
  # Keep stderr visible so validation warnings surface in CI logs; only the
  # verbose rendered config on stdout is discarded.
  docker compose config >/dev/null \
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
    drain_live "$LIVE" || true
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
  # Poll, don't single-shot: Caddy needs a health interval or two to
  # mark the stopped color down and fail `first` over to the idle one.
  READY_OK=0
  for _ in $(seq 1 30); do
    if edge_ready; then READY_OK=1; break; fi
    sleep 2
  done
  [ "$READY_OK" = "1" ] || fail "edge /ready is not 'ready' after switch"

  recover_color "$IDLE" "$DEPLOY_START" || true

  rm -f compose.yaml.bak Caddyfile.bak
  docker compose ps
  log "deploy complete, live=$IDLE"
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  reconcile) cmd_reconcile ;;
  recover) cmd_recover "$@" ;;
  *) fail "usage: $0 {deploy|reconcile|recover [blue|green]}" ;;
esac
