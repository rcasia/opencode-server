#!/bin/bash
# Exercises a real provider turn against one backend color or the TLS edge.
# Runs on the host; Caddy supplies curl and the machine-only credential.
set -euo pipefail

OPT_DIR="${OPT_DIR:-/opt/opencode}"
TARGET="${1:-edge}"
DEPLOYED_REF="${2:-unknown}"
COMPOSE=(docker compose -f "$OPT_DIR/compose.yaml")
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STARTED_EPOCH="$(date +%s)"
SESSION_ID=""

case "$TARGET" in edge | blue | green) ;; *) echo "invalid smoke target: $TARGET" >&2; exit 1 ;; esac

backend_request() {
  local method="$1" path="$2" body="${3:-}" timeout="${4:-10}"
  if [ "$TARGET" = edge ]; then
    "${COMPOSE[@]}" exec -T caddy sh -c '
      curl -sS --max-time "$4" --resolve "$DOMAIN:443:127.0.0.1" -X "$1" \
        -H "Authorization: Basic $BASIC_AUTH" \
        -H "Content-Type: application/json" \
        --data "$3" -w "\n%{http_code}" \
        "https://$DOMAIN/_prompt-smoke$2"
    ' -- "$method" "$path" "$body" "$timeout"
  else
    "${COMPOSE[@]}" exec -T caddy sh -c '
      curl -sS --max-time "$4" -X "$1" \
        -H "Authorization: Basic $BASIC_AUTH" \
        -H "Content-Type: application/json" \
        --data "$3" -w "\n%{http_code}" \
        "http://opencode-'"$TARGET"':4096$2"
    ' -- "$method" "$path" "$body" "$timeout"
  fi
}

cleanup() {
  [ -n "$SESSION_ID" ] || return 0
  backend_request DELETE "/session/$SESSION_ID" "" 10 >/dev/null 2>&1 || true
}

diagnostics() {
  rc=$?
  echo "prompt smoke failed: target=$TARGET ref=$DEPLOYED_REF session=${SESSION_ID:-none} started=$STARTED_AT" >&2
  "${COMPOSE[@]}" ps >&2 || true
  if [ -n "$SESSION_ID" ]; then
    backend_request GET "/session/$SESSION_ID/message?limit=10" "" 10 2>/dev/null \
      | sed '$d' | jq -c '[.[] | {info: {role: .info.role, finish: .info.finish, error: (if .info.error then {name: .info.error.name, message: .info.error.data.message, statusCode: .info.error.data.statusCode} else null end), time: .info.time}, parts: [.parts[] | select(.type == "text") | {type, text}]}]' >&2 || true
    if [ "$TARGET" = edge ]; then
      LIVE="$(cat "$OPT_DIR/.live-color" 2>/dev/null || echo blue)"
    else
      LIVE="$TARGET"
    fi
    "${COMPOSE[@]}" logs --no-color --since "$STARTED_AT" "opencode-$LIVE" 2>&1 | grep -F "$SESSION_ID" >&2 || true
  fi
  free -m >&2 || true
  dmesg | grep -iE 'killed process|out of memory' | tail -n 5 >&2 || true
  exit "$rc"
}
trap cleanup EXIT
trap diagnostics ERR

echo "prompt smoke: target=$TARGET ref=$DEPLOYED_REF started=$STARTED_AT"
CREATE="$(backend_request POST /session '{"title":"ci-prompt-smoke"}' 10)"
CREATE_CODE="${CREATE##*$'\n'}"
CREATE_BODY="${CREATE%$'\n'*}"
case "$CREATE_CODE" in 200 | 201) ;; *) echo "session create returned HTTP $CREATE_CODE" >&2; false ;; esac
SESSION_ID="$(printf '%s' "$CREATE_BODY" | jq -r '.id // empty')"
[ -n "$SESSION_ID" ] || { echo "session create returned no ID" >&2; false; }
echo "prompt smoke session: $SESSION_ID"

PROMPT='{"agent":"build","model":{"providerID":"opencode","modelID":"gpt-5.6-sol"},"parts":[{"type":"text","text":"Reply with exactly OK. Do not use tools."}]}'
PROMPT_RESULT="$(backend_request POST "/session/$SESSION_ID/prompt_async" "$PROMPT" 10)"
PROMPT_CODE="${PROMPT_RESULT##*$'\n'}"
[ "$PROMPT_CODE" = "204" ] || { echo "prompt_async returned HTTP $PROMPT_CODE" >&2; false; }
echo "prompt_async admitted: HTTP 204"

for _ in $(seq 1 45); do
  MESSAGES="$(backend_request GET "/session/$SESSION_ID/message?limit=10" "" 10)"
  MESSAGE_CODE="${MESSAGES##*$'\n'}"
  MESSAGE_BODY="${MESSAGES%$'\n'*}"
  [ "$MESSAGE_CODE" = "200" ] || { echo "message poll returned HTTP $MESSAGE_CODE" >&2; false; }
  if printf '%s' "$MESSAGE_BODY" | jq -e '.[] | select(.info.role == "assistant" and .info.error != null)' >/dev/null; then
    echo "assistant returned an error" >&2
    false
  fi
  if printf '%s' "$MESSAGE_BODY" | jq -e '.[] | select(.info.role == "assistant" and .info.time.completed != null and .info.error == null)' >/dev/null; then
    ANSWER="$(printf '%s' "$MESSAGE_BODY" | jq -r '[.[] | select(.info.role == "assistant")][-1].parts | map(select(.type == "text") | .text) | join("")' | xargs)"
    [ "$ANSWER" = "OK" ] || { echo "assistant completed with unexpected response" >&2; false; }
    echo "prompt smoke passed: completed assistant turn in $(( $(date +%s) - STARTED_EPOCH ))s"
    exit 0
  fi
  sleep 2
done

echo "assistant turn did not complete within 90s" >&2
false
