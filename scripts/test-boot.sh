#!/bin/bash
# Full-chain local test of app/ (ADR-0007, ADR-0014, ADR-0015): brings up
# the exact prod compose stack with dummy env, then asserts TLS -> SSO
# gate -> backend behavior, the public /ready gate, provider env/config
# wiring, and a zero-downtime blue-green switch.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"
cd "$APP_DIR"

DUMMY="boot-test-dummy"
BASIC_DUMMY="$(printf 'opencode:%s' "$DUMMY" | base64 | tr -d '\n')"
printf 'DOMAIN=%s\n' "localhost" > app.env
printf 'OPENCODE_%s=%s\n' "SERVER_PASSWORD" "$DUMMY" >> app.env
printf 'BASIC_AUTH=%s\n' "$BASIC_DUMMY" >> app.env
printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' "boot-test-client-id" >> app.env
printf 'OAUTH2_PROXY_GITHUB_USERS=%s\n' "boot-test-user" >> app.env
printf 'OAUTH2_PROXY_REDIRECT_URL=%s\n' "https://localhost/oauth2/callback" >> app.env
printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "boot-test-client-secret" >> app.env
printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "boot-test-cookie-secret-32b-min" >> app.env
printf 'ANTHROPIC_API_KEY=%s\n' "boot-test-anthropic-key" >> app.env
printf 'OPENAI_API_KEY=%s\n' "boot-test-openai-key" >> app.env
printf 'OPENCODE_API_KEY=%s\n' "boot-test-opencode-key" >> app.env
echo "blue" > .live-color
SAMPLER_LOG="$(mktemp)"
SAMPLER_PID=""
trap 'kill "$SAMPLER_PID" 2>/dev/null || true; docker compose down -v >/dev/null 2>&1; rm -f app.env .live-color "$SAMPLER_LOG"' EXIT

echo "==> Validating compose config"
# Keep stderr visible so validation warnings surface in CI logs; only the
# verbose rendered config on stdout is discarded.
docker compose config >/dev/null
jq empty opencode.json
grep -q '"apiKey": "{env:ANTHROPIC_API_KEY}"' opencode.json
grep -q '"apiKey": "{env:OPENAI_API_KEY}"' opencode.json
echo "PASS: opencode.json is valid JSON and uses env substitution for provider keys"

echo "==> Validating nono pilot pins (ADR-0025)"
jq empty nono-profile.json
jq empty nono-version.json
MANIFEST_VERSION="$(jq -r .version nono-version.json)"
USER_DATA_PIN="$(grep -m1 '^NONO_VERSION=' ../modules/compute/user_data.sh | cut -d'"' -f2)"
[ -n "$USER_DATA_PIN" ] && [ "$USER_DATA_PIN" = "$MANIFEST_VERSION" ] \
  || { echo "FAIL: user_data NONO_VERSION ($USER_DATA_PIN) != manifest ($MANIFEST_VERSION)"; exit 1; }
for _arch in x86_64 aarch64; do
  MANIFEST_SHA="$(jq -r ".artifacts.rpm_${_arch}.sha256" nono-version.json)"
  USER_DATA_SHA="$(grep "${_arch}) NONO_RPM=" ../modules/compute/user_data.sh | sed 's/.*NONO_SHA256="\([0-9a-f]*\)".*/\1/')"
  [ -n "$USER_DATA_SHA" ] && [ "$USER_DATA_SHA" = "$MANIFEST_SHA" ] \
    || { echo "FAIL: user_data nono SHA for $_arch ($USER_DATA_SHA) != manifest ($MANIFEST_SHA)"; exit 1; }
done
if command -v nono >/dev/null 2>&1; then
  nono profile validate ./nono-profile.json
  echo "PASS: nono-profile.json validates against the installed nono schema"
else
  echo "PASS: nono-profile.json is valid JSON (no local nono binary for schema validation)"
fi
echo "PASS: nono pins consistent (version $MANIFEST_VERSION, boot SHAs match manifest)"

echo "==> Fetching pinned nono Linux binary for the container mount"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) TAR_ARCH="x86_64" ;;
  aarch64|arm64) TAR_ARCH="aarch64" ;;
  *) echo "FAIL: unsupported arch $HOST_ARCH for nono test binary"; exit 1 ;;
esac
TAR_FILE="$(jq -r ".artifacts.tar_${TAR_ARCH}.file" nono-version.json)"
TAR_SHA="$(jq -r ".artifacts.tar_${TAR_ARCH}.sha256" nono-version.json)"
mkdir -p .nono-bin
curl -fsSL "https://github.com/nolabs-ai/nono/releases/download/v${MANIFEST_VERSION}/${TAR_FILE}" -o .nono-bin/nono.tar.gz
echo "${TAR_SHA}  .nono-bin/nono.tar.gz" | sha256sum -c -
tar -xzf .nono-bin/nono.tar.gz -C .nono-bin
test -x .nono-bin/nono || { echo "FAIL: nono binary missing after extract"; exit 1; }
export NONO_BIN="$APP_DIR/.nono-bin/nono"
echo "PASS: pinned nono binary ready at $NONO_BIN"

echo "==> Starting prod stack locally, live color blue (dummy env)"
docker compose up -d --wait --wait-timeout 180 caddy oauth2-proxy opencode-blue >/dev/null

echo "==> Waiting for https://localhost"
RESP=""
for _ in $(seq 1 30); do
  RESP="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 https://localhost/ || true)"
  [ -n "$RESP" ] && [ "$RESP" != "000 " ] && break
  sleep 4
done
echo "    unauthenticated response: $RESP"
case "$RESP" in
  302*oauth2*) echo "PASS: SSO gate redirects logged-out browsers into /oauth2/* (through Caddy TLS)";;
  *) echo "FAIL: expected 302 to /oauth2/* without a session, got $RESP"; exit 1;;
esac

DENY="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://localhost/oauth2/auth || true)"
echo "    /oauth2/auth status: $DENY"
case "$DENY" in
  401|403) echo "PASS: oauth2-proxy deny path answers $DENY without a session";;
  *) echo "FAIL: expected 401/403 from /oauth2/auth, got $DENY"; exit 1;;
esac

PING_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://localhost/ping)"
[ "$PING_CODE" = "200" ] || { echo "FAIL: /ping returned $PING_CODE, body:"; curl -sk https://localhost/ping; exit 1; }
echo "PASS: unauthenticated /ping returns 200 (edge-liveness path)"

READY_BODY="$(curl -sk --max-time 10 https://localhost/ready || true)"
[ "$READY_BODY" = "ready" ] || { echo "FAIL: /ready body is '$READY_BODY', want 'ready'"; exit 1; }
echo "PASS: public /ready answers 'ready' (a backend color answers behind the edge)"

echo "==> Asserting backend password and provider keys are wired"
[ "$(docker compose exec -T opencode-blue printenv OPENCODE_SERVER_PASSWORD)" = "$DUMMY" ] \
  || { echo "FAIL: OPENCODE_SERVER_PASSWORD not set in backend"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv ANTHROPIC_API_KEY)" = "boot-test-anthropic-key" ] \
  || { echo "FAIL: ANTHROPIC_API_KEY not set in backend"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv OPENAI_API_KEY)" = "boot-test-openai-key" ] \
  || { echo "FAIL: OPENAI_API_KEY not set in backend"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv OPENCODE_API_KEY)" = "boot-test-opencode-key" ] \
  || { echo "FAIL: OPENCODE_API_KEY not set in backend"; exit 1; }
[ "$(docker compose exec -T opencode-blue test -f /root/.config/opencode/opencode.json)" ] \
  || { echo "FAIL: managed opencode.json not mounted"; exit 1; }
echo "PASS: backend receives provider credentials through app.env and managed config is mounted"
# No 2>/dev/null: adapt warnings must surface in the log; stdout still pipes
# to grep so the JSON response remains quiet unless it proves the header.
docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
  | grep -q 'Authorization' || { echo "FAIL: Caddy injects no Authorization header"; exit 1; }
echo "PASS: Caddy injects Basic auth to the backend after SSO"

echo "==> Validating live Caddyfile"
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
echo "==> Asserting restart contract (blue live, green stopped)"
[ "$(docker inspect "$(docker compose ps -q caddy)" --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect "$(docker compose ps -q opencode-blue)" --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect "$(docker compose ps -q oauth2-proxy)" --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ -z "$(docker compose ps -q opencode-green)" ] || { echo "FAIL: idle color green is running before the switch"; exit 1; }
[ "$(docker inspect "$(docker compose ps -q caddy)" --format '{{.State.Health.Status}}')" = "healthy" ]
[ "$(docker inspect "$(docker compose ps -q oauth2-proxy)" --format '{{.State.Running}}')" = "true" ]
echo "PASS: all services restart=always, caddy healthy, oauth2-proxy running, green stopped"

echo "==> Rehearsing zero-downtime switch (blue -> green via switch.sh)"
sampler() {
  while true; do
    BODY="$(curl -sk --max-time 3 https://localhost/ready || echo CURL-FAIL)"
    [ "$BODY" = "ready" ] || echo "ready='$BODY'" >>"$SAMPLER_LOG"
    ROOT="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 3 https://localhost/ || echo CURL-FAIL)"
    case "$ROOT" in 302*oauth2*) ;; *) echo "root='$ROOT'" >>"$SAMPLER_LOG";; esac
    sleep 0.2
  done
}
sampler &
SAMPLER_PID=$!
COMPOSE_DIR="$APP_DIR" READY_TIMEOUT=60 ./switch.sh deploy
kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
if [ -s "$SAMPLER_LOG" ]; then
  echo "FAIL: traffic saw failures during the switch:"
  cat "$SAMPLER_LOG"
  exit 1
fi
echo "PASS: /ready stayed 'ready' and / stayed at the SSO gate for the whole switch"

echo "==> Asserting post-switch state (green live, blue stopped)"
[ "$(cat .live-color)" = "green" ] || { echo "FAIL: .live-color is $(cat .live-color), want green"; exit 1; }
[ -n "$(docker compose ps --status running --services | grep -x 'opencode-green')" ] \
  || { echo "FAIL: opencode-green not running after switch"; exit 1; }
[ -z "$(docker compose ps -q opencode-blue)" ] || { echo "FAIL: opencode-blue still present after switch"; exit 1; }
[ "$(curl -sk --max-time 10 https://localhost/ready)" = "ready" ] \
  || { echo "FAIL: /ready not 'ready' after switch"; exit 1; }
ROOT_AFTER="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 https://localhost/)"
case "$ROOT_AFTER" in
  302*oauth2*) echo "PASS: green serves through the edge, SSO gate intact ($ROOT_AFTER)";;
  *) echo "FAIL: expected 302 to /oauth2/* after switch, got $ROOT_AFTER"; exit 1;;
esac
echo "==> Probing constrained recovery (issue #32: detect/mark + diff-gated retry)"
RSID="$(docker compose exec -T caddy sh -c 'curl -s --max-time 10 -X POST -H "Authorization: Basic $BASIC_AUTH" -H "Content-Type: application/json" -d '\''{"title":"recovery-probe"}'\'' http://opencode-green:4096/session' | jq -r .id)"
[ -n "$RSID" ] && [ "$RSID" != "null" ] || { echo "FAIL: could not create recovery probe session"; exit 1; }
docker compose exec -T caddy sh -c 'curl -s --max-time 10 -X POST -H "Authorization: Basic $BASIC_AUTH" -H "Content-Type: application/json" -d '\''{"parts":[{"type":"text","text":"recovery probe"}],"model":{"providerID":"anthropic","modelID":"claude-sonnet-4-5"},"agent":"build","noReply":true}'\'' http://opencode-green:4096/session/'"$RSID"'/message' >/dev/null \
  || { echo "FAIL: could not seed dangling user message"; exit 1; }
COMPOSE_DIR="$APP_DIR" ./switch.sh recover green
RTITLE="$(docker compose exec -T caddy sh -c 'curl -s --max-time 10 -H "Authorization: Basic $BASIC_AUTH" http://opencode-green:4096/session/'"$RSID" | jq -r .title)"
case "$RTITLE" in
  "[interrupted-by-deploy]"*) echo "PASS: interrupted session marked ($RTITLE), empty-diff retry fired";;
  *) echo "FAIL: recovery probe session not marked, title='$RTITLE'"; exit 1;;
esac
echo "ALL BOOT CHECKS PASSED"
