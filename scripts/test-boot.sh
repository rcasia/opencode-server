#!/bin/bash
# Full-chain local test of app/ (ADR-0007): brings up the exact prod compose
# stack with dummy env, then asserts TLS -> proxy -> auth behavior.
# DOMAIN=localhost gets Caddy a local CA cert, so `curl -k` exercises real
# HTTPS through the same Caddyfile prod uses.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"
cd "$APP_DIR"

DUMMY="boot-test-dummy"
printf 'DOMAIN=%s\n' "localhost" > app.env
printf 'OPENCODE_%s=%s\n' "SERVER_PASSWORD" "$DUMMY" >> app.env
trap 'docker compose down -v >/dev/null 2>&1; rm -f app.env' EXIT

echo "==> Validating compose config"
docker compose config --quiet
echo "==> Starting prod stack locally (dummy env)"
docker compose up -d --wait --wait-timeout 180 >/dev/null

echo "==> Waiting for https://localhost"
CODE=""
for _ in $(seq 1 30); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost/ || true)"
  [ -n "$CODE" ] && [ "$CODE" != "000" ] && break
  sleep 4
done
echo "    unauthenticated status: $CODE"
[ "$CODE" = "401" ] || { echo "FAIL: expected 401 without credentials, got $CODE"; exit 1; }
echo "PASS: auth gate returns 401 without credentials (through Caddy TLS)"

AUTH_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -u "opencode:$DUMMY" https://localhost/)"
echo "    authenticated status: $AUTH_CODE"
[ "$AUTH_CODE" != "401" ] && [ "$AUTH_CODE" != "000" ] || { echo "FAIL: authenticated request rejected ($AUTH_CODE)"; exit 1; }
echo "PASS: authenticated request accepted ($AUTH_CODE)"

echo "==> Validating live Caddyfile"
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
echo "==> Asserting restart contract"
[ "$(docker inspect app-caddy-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect app-opencode-1 --format '{{.HostConfig.RestartPolicy.Name}}')" = "always" ]
[ "$(docker inspect app-caddy-1 --format '{{.State.Health.Status}}')" = "healthy" ]
echo "PASS: both services restart=always, caddy healthy"
echo "ALL BOOT CHECKS PASSED"
