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
printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "boot-test-cookie-secret-32bytes!" >> app.env # exactly 32 bytes: oauth2-proxy demands 16/24/32
printf 'ANTHROPIC_API_KEY=%s\n' "boot-test-anthropic-key" >> app.env
printf 'OPENAI_API_KEY=%s\n' "boot-test-openai-key" >> app.env
printf 'OPENCODE_API_KEY=%s\n' "boot-test-opencode-key" >> app.env
echo "blue" > .live-color
SAMPLER_LOG="$(mktemp)"
SAMPLER_PID=""
teardown() {
  _rc=$?
  # Every failure path dumps first: explicit `exit 1` assertions skip
  # the ERR trap, so the EXIT trap carries the dump. Backend logs are
  # the only record of a sandbox that crash-loops, and `compose down
  # -v` below deletes them.
  [ "$_rc" -ne 0 ] && dump_backend_state
  kill "$SAMPLER_PID" 2>/dev/null || true
  docker compose down -v >/dev/null 2>&1
  rm -f app.env .live-color compose.override.yaml "$SAMPLER_LOG"
}
trap 'teardown' EXIT
# Dump backend state before the EXIT trap tears the stack down: a
# sandbox that crash-loops leaves its reason only in container logs,
# and `compose down -v` deletes them.
dump_backend_state() {
  echo "==> FAILURE: backend state"
  docker compose ps || true
  docker compose logs --no-color --tail 200 opencode-blue opencode-green 2>&1 || true
  docker compose logs --no-color --tail 60 caddy 2>&1 || true
}
trap 'dump_backend_state' ERR

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
MANIFEST_TAR="$(jq -r .artifacts.tar_musl_x86_64.file nono-version.json)"
MANIFEST_TAR_SHA="$(jq -r .artifacts.tar_musl_x86_64.sha256 nono-version.json)"
USER_DATA_VERSION="$(grep -m1 '^NONO_VERSION=' ../modules/compute/user_data.sh | cut -d'"' -f2)"
[ -n "$USER_DATA_VERSION" ] || { echo "FAIL: user_data sets no NONO_VERSION pin"; exit 1; }
# user_data builds the tarball name from $NONO_VERSION at boot time;
# resolve the same expansion here before comparing with the manifest.
USER_DATA_TAR="$(grep -m1 '^NONO_TAR=' ../modules/compute/user_data.sh | cut -d'"' -f2 | sed "s/\$NONO_VERSION/$USER_DATA_VERSION/")"
[ -n "$USER_DATA_TAR" ] || { echo "FAIL: user_data sets no NONO_TAR pin"; exit 1; }
[ "$USER_DATA_VERSION" = "$MANIFEST_VERSION" ] \
  || { echo "FAIL: user_data NONO_VERSION ($USER_DATA_VERSION) != manifest ($MANIFEST_VERSION)"; exit 1; }
for _field in file sha256; do
  MANIFEST_VAL="$(jq -r ".artifacts.tar_musl_x86_64.$_field" nono-version.json)"
  case "$_field" in
    file) USER_DATA_VAL="$USER_DATA_TAR" ;;
    sha256) USER_DATA_VAL="$(grep -m1 '^NONO_TAR_SHA256=' ../modules/compute/user_data.sh | cut -d'"' -f2)" ;;
  esac
  [ -n "$USER_DATA_VAL" ] && [ "$USER_DATA_VAL" = "$MANIFEST_VAL" ] \
    || { echo "FAIL: user_data musl tarball $_field ($USER_DATA_VAL) != manifest ($MANIFEST_VAL)"; exit 1; }
done
if command -v nono >/dev/null 2>&1; then
  nono profile validate ./nono-profile.json
  echo "PASS: nono-profile.json validates against the installed nono schema"
else
  echo "PASS: nono-profile.json is valid JSON (no local nono binary for schema validation)"
fi
echo "PASS: nono pins consistent (version $MANIFEST_VERSION, boot SHAs match manifest)"

echo "==> Fetching pinned nono musl binary for the container mount"
# The container binary is the x86_64-musl build (static-pie): the only
# upstream asset that execs on the Alpine backend image. ARM hosts
# cannot execute it (no aarch64-musl asset upstream), so no sandbox
# can run there: the backend runs plain via a throwaway override
# (trap-removed, never committed) and the enforcement probes below
# self-skip on the live check. Wiring/SSO/switch/config still prove
# out on every arch.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) ;;
  aarch64|arm64)
    cat > compose.override.yaml <<'OVERRIDE_EOF'
# test-boot only, ARM hosts (gitignored, trap-removed): run the
# backend without the sandbox so serving behavior still proves out.
# The image ENTRYPOINT is ["opencode"], hence entrypoint here.
services:
  opencode-blue:
    entrypoint: ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]
  opencode-green:
    entrypoint: ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]
OVERRIDE_EOF
    echo "    ARM host: plain-backend override written (sandbox probes will self-skip)"
    echo "    Pulling native images (a prior run may have cached another arch)"
    docker compose config --images 2>/dev/null | xargs docker image rm -f >/dev/null 2>&1 || true
    docker compose pull caddy oauth2-proxy opencode-blue
    ;;
  *) echo "FAIL: unsupported arch $HOST_ARCH for this test"; exit 1 ;;
esac
mkdir -p .nono-bin
curl -fsSL "https://github.com/nolabs-ai/nono/releases/download/v${MANIFEST_VERSION}/${MANIFEST_TAR}" -o .nono-bin/nono.tar.gz
echo "${MANIFEST_TAR_SHA}  .nono-bin/nono.tar.gz" | sha256sum -c -
tar -xzf .nono-bin/nono.tar.gz -C .nono-bin
test -x .nono-bin/nono || { echo "FAIL: nono binary missing after extract"; exit 1; }
cp -f .nono-bin/nono nono-container
chmod +x nono-container
echo "PASS: pinned musl nono binary ready at $APP_DIR/nono-container"

echo "==> Starting prod stack locally, live color blue (dummy env)"
# --no-deps: caddy depends_on both colors, so a plain up creates blue
# and green in parallel. Both mount the same workspace volume and the
# daemon loses a mkdir race inside it (failed to mkdir
# .../app_opencode-workspace/_data/.cache: file exists), failing the
# whole up. Green is created later, serially, by the switch rehearsal —
# exactly like the host reconcile does.
docker compose up -d --no-deps --wait --wait-timeout 180 caddy oauth2-proxy opencode-blue >/dev/null

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
docker compose exec -T opencode-blue test -f /root/.config/opencode/opencode.json \
  || { echo "FAIL: managed opencode.json not mounted"; exit 1; }
echo "PASS: backend receives provider credentials through app.env and managed config is mounted"
# No 2>/dev/null: adapt warnings must surface in the log; stdout still pipes
# to grep so the JSON response remains quiet unless it proves the header.
docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
  | grep -q 'Authorization' || { echo "FAIL: Caddy injects no Authorization header"; exit 1; }
echo "PASS: Caddy injects Basic auth to the backend after SSO"

echo "==> Asserting sandbox profile (issue #31, ADR-0025)"
# Probes run through a nested `nono run` with the same profile the
# backend itself runs under: identical policy, tightened-or-equal
# Landlock inheritance. Plain `docker compose exec` spawns outside the
# sandbox and would prove nothing here.
SANDBOX_NONO="/usr/local/bin/nono"
SANDBOX_PROFILE="/etc/nono/profile.json"
sandbox() {
  docker compose exec -T opencode-blue "$SANDBOX_NONO" run --silent --allow-cwd --profile "$SANDBOX_PROFILE" -- "$@"
}
# Enforcement probes only mean something where the sandbox can
# initialize (Landlock on a native kernel). Where it cannot (e.g. ARM
# hosts running the plain-backend override), they self-skip instead of
# failing: the serving/switch asserts above still prove the wiring.
SANDBOX_LIVE=0
if sandbox true >/dev/null 2>&1; then
  SANDBOX_LIVE=1
  echo "PASS: sandbox initializes in backend (enforcement probes apply)"
else
  echo "SKIP: sandbox unavailable in backend on this host (enforcement probes skipped)"
fi
# Mount cut holds with or without a live sandbox (plain exec sees mounts).
docker compose exec -T opencode-blue test '!' -e /var/run/docker.sock \
  || { echo "FAIL: /var/run/docker.sock exists in backend (mount not cut)"; exit 1; }
echo "PASS: docker.sock mount is cut (socket absent in backend)"
if [ "$SANDBOX_LIVE" = "1" ]; then
why_allow() {
  OUT="$(sandbox "$SANDBOX_NONO" why --self "$@" --json 2>&1)" \
    || { echo "FAIL: why query failed: $*"; printf '%s\n' "$OUT"; exit 1; }
  printf '%s' "$OUT" | grep -q '"status":"allowed"' \
    || { echo "FAIL: expected sandbox to allow: $*"; printf '%s\n' "$OUT"; exit 1; }
  echo "PASS: sandbox allows $*"
}
why_deny() {
  OUT="$(sandbox "$SANDBOX_NONO" why --self "$@" --json 2>&1)" \
    || { echo "FAIL: why query failed: $*"; printf '%s\n' "$OUT"; exit 1; }
  printf '%s' "$OUT" | grep -q '"status":"denied"' \
    || { echo "FAIL: expected sandbox to deny: $*"; printf '%s\n' "$OUT"; exit 1; }
  echo "PASS: sandbox denies $*"
}
why_allow --path /root --op write
why_allow --host https://api.anthropic.com
why_allow --host https://api.github.com
why_deny --path /root/.aws --op read
why_deny --path /var/run/docker.sock --op read
why_deny --host http://169.254.169.254/
sandbox sh -c 'command -v wget >/dev/null' \
  || { echo "FAIL: no http client in backend for the IMDS probe"; exit 1; }
sandbox sh -c 'wget -q -T 5 -O /dev/null http://169.254.169.254/ 2>/dev/null' \
  && { echo "FAIL: IMDS reachable from inside sandbox"; exit 1; } \
  || echo "PASS: IMDS unreachable from inside sandbox"
sandbox git --version >/dev/null \
  || { echo "FAIL: git missing in sandboxed backend (issue #35)"; exit 1; }
sandbox sh -c 'rm -rf /tmp/sandbox-probe && mkdir -p /tmp/sandbox-probe && cd /tmp/sandbox-probe && git init -q && git -c user.name=sandbox -c user.email=sandbox@test commit -q --allow-empty -m probe && test -n "$(git rev-parse HEAD)"' \
  || { echo "FAIL: git commit does not work inside sandbox"; exit 1; }
echo "PASS: git works inside sandbox (init + commit)"

echo "==> Probing provider egress with a dummy-credential model call"
MODEL_OUT="$(sandbox timeout 120 opencode run 'reply with the single word ok' 2>&1 || true)"
if printf '%s' "$MODEL_OUT" | grep -qiE '401|unauthori[sz]ed|invalid api key|invalid.*key|authentication failed'; then
  echo "PASS: provider egress allowed (dummy key rejected with auth error, not blocked)"
elif printf '%s' "$MODEL_OUT" | grep -qiE 'proxy|denied|ECONN|ENOTFOUND|ETIMEDOUT|network|socket hang up|fetch failed'; then
  echo "FAIL: provider egress blocked from inside sandbox:"
  printf '%s\n' "$MODEL_OUT"
  exit 1
else
  echo "FAIL: unexpected model-call output (neither auth error nor block):"
  printf '%s\n' "$MODEL_OUT"
  exit 1
fi
fi # SANDBOX_LIVE

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
    TS="$(date +%T)"
    BODY="$(curl -sk --max-time 3 https://localhost/ready || echo CURL-FAIL)"
    [ "$BODY" = "ready" ] || echo "$TS ready='$BODY'" >>"$SAMPLER_LOG"
    ROOT="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 3 https://localhost/ || echo CURL-FAIL)"
    case "$ROOT" in 302*oauth2*) ;; *) echo "$TS root='$ROOT'" >>"$SAMPLER_LOG";; esac
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
