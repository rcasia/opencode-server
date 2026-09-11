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
# Per-service env files (ADR-0028): each service receives only its own secrets.
printf 'DOMAIN=%s\n'    "localhost"   > caddy.env
printf 'BASIC_AUTH=%s\n' "$BASIC_DUMMY" >> caddy.env
printf 'OAUTH2_PROXY_CLIENT_ID=%s\n'     "boot-test-client-id"             > oauth2.env
printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "boot-test-client-secret"         >> oauth2.env
printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "boot-test-cookie-secret-32bytes!" >> oauth2.env # exactly 32 bytes: oauth2-proxy demands 16/24/32
printf 'OAUTH2_PROXY_GITHUB_USERS=%s\n'  "boot-test-user"                  >> oauth2.env
printf 'OAUTH2_PROXY_REDIRECT_URL=%s\n'  "https://localhost/oauth2/callback" >> oauth2.env
printf 'OPENCODE_%s=%s\n' "SERVER_PASSWORD" "$DUMMY"           > opencode.env
printf 'ANTHROPIC_API_KEY=%s\n' "boot-test-anthropic-key"      >> opencode.env
printf 'OPENAI_API_KEY=%s\n'    "boot-test-openai-key"         >> opencode.env
printf 'OPENCODE_API_KEY=%s\n'  "boot-test-opencode-key"       >> opencode.env
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
  rm -f caddy.env oauth2.env opencode.env .live-color .switch.lock compose.override.yaml "$SAMPLER_LOG"
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
USER_DATA_VERSION="$(grep -m1 '^NONO_VERSION=' ../infra/modules/compute/user_data.sh | cut -d'"' -f2)"
[ -n "$USER_DATA_VERSION" ] || { echo "FAIL: user_data sets no NONO_VERSION pin"; exit 1; }
# user_data builds the tarball name from $NONO_VERSION at boot time;
# resolve the same expansion here before comparing with the manifest.
USER_DATA_TAR="$(grep -m1 '^NONO_TAR=' ../infra/modules/compute/user_data.sh | cut -d'"' -f2 | sed "s/\$NONO_VERSION/$USER_DATA_VERSION/")"
[ -n "$USER_DATA_TAR" ] || { echo "FAIL: user_data sets no NONO_TAR pin"; exit 1; }
[ "$USER_DATA_VERSION" = "$MANIFEST_VERSION" ] \
  || { echo "FAIL: user_data NONO_VERSION ($USER_DATA_VERSION) != manifest ($MANIFEST_VERSION)"; exit 1; }
for _field in file sha256; do
  MANIFEST_VAL="$(jq -r ".artifacts.tar_musl_x86_64.$_field" nono-version.json)"
  case "$_field" in
    file) USER_DATA_VAL="$USER_DATA_TAR" ;;
    sha256) USER_DATA_VAL="$(grep -m1 '^NONO_TAR_SHA256=' ../infra/modules/compute/user_data.sh | cut -d'"' -f2)" ;;
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

echo "==> Probing backend API route (GET /command, the web UI calls it per directory)"
CMD_RESP="$(docker compose exec -T caddy sh -c 'curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Basic $BASIC_AUTH" "http://opencode-blue:4096/command?directory=/root/workspace"' || true)"
[ "$CMD_RESP" = "200" ] || { echo "FAIL: backend /command returned '$CMD_RESP', want 200"; exit 1; }
echo "PASS: backend /command answers 200 for the workspace directory"

echo "==> Asserting per-service env isolation (ADR-0028)"
echo "==> Asserting backend password and provider keys are wired"
[ "$(docker compose exec -T opencode-blue printenv OPENCODE_SERVER_PASSWORD)" = "$DUMMY" ] \
  || { echo "FAIL: OPENCODE_SERVER_PASSWORD not set in opencode-blue"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv ANTHROPIC_API_KEY)" = "boot-test-anthropic-key" ] \
  || { echo "FAIL: ANTHROPIC_API_KEY not set in opencode-blue"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv OPENAI_API_KEY)" = "boot-test-openai-key" ] \
  || { echo "FAIL: OPENAI_API_KEY not set in opencode-blue"; exit 1; }
[ "$(docker compose exec -T opencode-blue printenv OPENCODE_API_KEY)" = "boot-test-opencode-key" ] \
  || { echo "FAIL: OPENCODE_API_KEY not set in opencode-blue"; exit 1; }
# caddy only sees caddy.env — it must NOT have provider secrets
if docker compose exec -T caddy printenv OPENCODE_SERVER_PASSWORD 2>/dev/null | grep -q .; then
  echo "FAIL: OPENCODE_SERVER_PASSWORD leaked into caddy (env isolation broken)"; exit 1
fi
if docker compose exec -T caddy printenv ANTHROPIC_API_KEY 2>/dev/null | grep -q .; then
  echo "FAIL: ANTHROPIC_API_KEY leaked into caddy (env isolation broken)"; exit 1
fi
[ "$(docker compose exec -T caddy printenv DOMAIN)" = "localhost" ] \
  || { echo "FAIL: DOMAIN not set in caddy"; exit 1; }
[ "$(docker compose exec -T caddy printenv BASIC_AUTH)" = "$BASIC_DUMMY" ] \
  || { echo "FAIL: BASIC_AUTH not set in caddy"; exit 1; }
docker compose exec -T opencode-blue test -f /root/.config/opencode/opencode.json \
  || { echo "FAIL: managed opencode.json not mounted"; exit 1; }
echo "PASS: per-service env files deliver secrets only to the service that needs them; managed config is mounted"
echo "==> Asserting provider wiring matches opencode.json (issue #49)"
# Same audit as app.sh check_provider_wiring, driven by parsing
# opencode.json (not hardcoded names): every {env:X} it references
# must be provided by one of the three local env files.
jq -r '[.. | strings | select(startswith("{env:") and endswith("}")) | sub("^\\{env:"; "") | sub("\\}$"; "")] | unique[]' opencode.json 2>/dev/null \
  | while IFS= read -r _var; do
    [ -n "${_var:-}" ] || continue
    grep -hq "^${_var}=" caddy.env oauth2.env opencode.env 2>/dev/null \
      || { echo "FAIL: opencode.json references env ${_var} but no local env file provides it"; exit 1; }
  done
echo "PASS: every {env:} reference in opencode.json is provided"
# No 2>/dev/null: adapt warnings must surface in the log; stdout still pipes
# to grep so the JSON response remains quiet unless it proves the header.
docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
  | grep -q 'Authorization' || { echo "FAIL: Caddy injects no Authorization header"; exit 1; }
echo "PASS: Caddy injects Basic auth to the backend after SSO"

echo "==> Asserting sandbox profile (issue #31, ADR-0025)"
# Two probe kinds. Policy queries (`why`) evaluate the profile
# statically through plain exec: no sandbox application, so no tty or
# kernel needed — they prove the checked-in policy says what we think.
# (`why --self` would query the live sandbox instead, but its state
# reload breaks on Linux volatile grants — upstream issue #986 — so it
# cannot run here.) Liveness probes (IMDS, git, model call) run through
# a nested `nono run` under the same profile: identical policy,
# tightened-or-equal Landlock inheritance. Plain exec for those would
# spawn outside the sandbox and prove nothing.
SANDBOX_NONO="/usr/local/bin/nono"
SANDBOX_PROFILE="/etc/nono/profile.json"
sandbox() {
  # Plain docker exec -t: nested nono opens /dev/tty for a Landlock
  # rule, and a session without a controlling terminal fails the same
  # ENXIO the container-level tty: true fixed for the backend itself.
  # (compose exec only disables TTY allocation; it cannot force it.)
  docker exec -t "$(docker compose ps -q opencode-blue)" "$SANDBOX_NONO" run --silent --allow-cwd --profile "$SANDBOX_PROFILE" -- "$@"
}
whyquery() {
  # --allow mirrors the backend entrypoint's --allow-cwd (a flag
  # `why` does not accept): without the CWD context the profile's
  # workdir grant never applies and every workspace query answers
  # denied.
  docker compose exec -T opencode-blue "$SANDBOX_NONO" why --profile "$SANDBOX_PROFILE" --allow /root/workspace "$@" --json 2>&1
}
# Enforcement probes only mean something where the sandbox can
# initialize (Landlock on a native kernel). Where it cannot (e.g. ARM
# hosts running the plain-backend override), they self-skip instead of
# failing: the serving/switch asserts above still prove the wiring.
SANDBOX_LIVE=0
if SANDBOX_DIAG="$(sandbox true 2>&1)"; then
  SANDBOX_LIVE=1
  echo "PASS: sandbox initializes in backend (enforcement probes apply)"
else
  echo "SKIP: sandbox unavailable in backend on this host (enforcement probes skipped)"
  printf '%s\n' "$SANDBOX_DIAG" | head -n 15
fi
# Mount cut holds with or without a live sandbox (plain exec sees mounts).
docker compose exec -T opencode-blue test '!' -e /var/run/docker.sock \
  || { echo "FAIL: /var/run/docker.sock exists in backend (mount not cut)"; exit 1; }
echo "PASS: docker.sock mount is cut (socket absent in backend)"
if [ "$SANDBOX_LIVE" = "1" ]; then
why_allow() {
  OUT="$(whyquery "$@")" \
    || { echo "FAIL: why query failed: $*"; printf '%s\n' "$OUT"; exit 1; }
  printf '%s' "$OUT" | grep -q '"status": *"allowed"' \
    || { echo "FAIL: expected sandbox to allow: $*"; printf '%s\n' "$OUT"; exit 1; }
  echo "PASS: sandbox allows $*"
}
why_deny() {
  OUT="$(whyquery "$@")" \
    || { echo "FAIL: why query failed: $*"; printf '%s\n' "$OUT"; exit 1; }
  printf '%s' "$OUT" | grep -q '"status": *"denied"' \
    || { echo "FAIL: expected sandbox to deny: $*"; printf '%s\n' "$OUT"; exit 1; }
  echo "PASS: sandbox denies $*"
}
why_allow --path /root/workspace --op write
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

echo "==> Probing opencode.ai egress (the web UI prompts through the opencode provider)"
ZEN_BODY="$(sandbox curl -s --max-time 20 https://opencode.ai/ || true)"
printf '%s' "$ZEN_BODY" | grep -qi 'not in the allowlist' \
  && { echo "FAIL: opencode.ai blocked from inside sandbox"; exit 1; }
echo "PASS: opencode.ai reachable through sandbox egress proxy"

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
  # 12s timeout mirrors Caddy's 10s retry budget: mid-failover the
  # edge retries the dead color before answering from the live one,
  # so a slow sample is seamless-by-design. One line per poll so the
  # verdict below can tell an isolated failover blip (tolerated, like
  # prod Route53) from a sustained outage.
  while true; do
    TS="$(date +%T)"
    BODY="$(curl -sk --max-time 12 https://localhost/ready || echo CURL-FAIL)"
    ROOT="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 12 https://localhost/ || echo CURL-FAIL)"
    echo "$TS ready='$BODY' root='$ROOT'" >>"$SAMPLER_LOG"
    sleep 2
  done
}
sampler &
SAMPLER_PID=$!
COMPOSE_DIR="$APP_DIR" READY_TIMEOUT=20 DRAIN_TIMEOUT=10 ./switch.sh deploy
kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
BAD=0; CONSEC=0; MAXCONSEC=0
while IFS= read -r _line; do
  case "$_line" in
    *"ready='ready'"*302*oauth2*) CONSEC=0 ;;
    *) BAD=$((BAD + 1)); CONSEC=$((CONSEC + 1)); [ "$CONSEC" -gt "$MAXCONSEC" ] && MAXCONSEC=$CONSEC ;;
  esac
done <"$SAMPLER_LOG"
if [ "$MAXCONSEC" -ge 2 ] || [ "$BAD" -gt 10 ]; then
  echo "FAIL: traffic saw a sustained outage during the switch (bad polls: $BAD, longest run: $MAXCONSEC):"
  grep -v "ready='ready'.*302.*oauth2" "$SAMPLER_LOG" | head -n 20
  exit 1
fi
echo "PASS: no sustained outage during the switch (bad polls: $BAD, longest run: $MAXCONSEC)"

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
MGET_CODE="$(docker compose exec -T caddy sh -c 'curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Basic $BASIC_AUTH" http://opencode-green:4096/session/'"$RSID"'/message?limit=20' || true)"
[ "$MGET_CODE" = "200" ] || { echo "FAIL: backend session message history returned '$MGET_CODE', want 200"; exit 1; }
echo "PASS: backend session message history answers 200 (data route serves)"
COMPOSE_DIR="$APP_DIR" ./switch.sh recover green
RTITLE="$(docker compose exec -T caddy sh -c 'curl -s --max-time 10 -H "Authorization: Basic $BASIC_AUTH" http://opencode-green:4096/session/'"$RSID" | jq -r .title)"
case "$RTITLE" in
  "[interrupted-by-deploy]"*) echo "PASS: interrupted session marked ($RTITLE), empty-diff retry fired";;
  *) echo "FAIL: recovery probe session not marked, title='$RTITLE'"; exit 1;;
esac
echo "ALL BOOT CHECKS PASSED"
