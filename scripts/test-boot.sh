#!/bin/bash
# Full-chain local test of app/ (ADR-0007, ADR-0014): brings up the exact
# prod compose stack with dummy env, then asserts TLS -> SSO gate ->
# backend behavior. DOMAIN=localhost gets Caddy a local CA cert, so
# `curl -k` exercises real HTTPS through the same Caddyfile prod uses.
# The real GitHub flow is not testable locally — dummy OAuth values prove
# the wiring (logged-out redirects into /oauth2/*, /oauth2/auth denies),
# not the IdP round-trip.
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
trap 'docker compose down -v >/dev/null 2>&1; rm -f app.env' EXIT

echo "==> Validating compose config"
docker compose config --quiet
echo "==> Starting prod stack locally (dummy env)"
docker compose up -d --wait --wait-timeout 180 >/dev/null

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
echo "PASS: unauthenticated /ping returns 200 (uptime probe path)"

echo "==> Asserting backend password still wired (machine-only)"
[ "$(docker compose exec -T opencode printenv OPENCODE_SERVER_PASSWORD)" = "$DUMMY" ] \
  || { echo "FAIL: OPENCODE_SERVER_PASSWORD not set in backend"; exit 1; }
echo "PASS: backend still requires its password (never typed by a human)"
docker compose exec -T caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null \
  | grep -q 'Authorization' || { echo "FAIL: Caddy injects no Authorization header"; exit 1; }
echo "PASS: Caddy injects Basic auth to the backend after SSO"

echo "==> Validating live Caddyfile"
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
echo "==> Asserting restart contract"
[ "$(docker inspect app-caddy-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect app-opencode-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect app-oauth2-proxy-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect app-caddy-1 --format '{{.State.Health.Status}}')" = "healthy" ]
[ "$(docker inspect app-oauth2-proxy-1 --format '{{.State.Running}}')" = "true" ]
echo "PASS: all services restart=always, caddy healthy, oauth2-proxy running"
echo "ALL BOOT CHECKS PASSED"
