#!/bin/bash
# Application stage of instance boot (ADR-0024). Runs once at boot
# (`app.sh boot`, called by user_data) and re-runs over SSM on app-only
# changes (`app.sh refresh`, `app.sh secrets`, `app.sh git-setup`) with
# seconds of blip and no host replacement.
#
# Static file: shipped via the S3 app bundle, never rendered by
# Terraform. Non-secret config comes from /opt/opencode/stage.env
# (written once by bootstrap from Terraform vars); secret VALUES come
# only from SSM at runtime and never touch git, logs, or the bundle.
set -euo pipefail

OPT_DIR="${OPT_DIR:-/opt/opencode}"
STAGE_ENV="${STAGE_ENV:-$OPT_DIR/stage.env}"
PROVIDER_MAP="${PROVIDER_MAP:-$OPT_DIR/provider-map.sh}"
COMPOSE="${COMPOSE:-docker compose -f $OPT_DIR/compose.yaml}"

[ -f "$STAGE_ENV" ] || { echo "FATAL: $STAGE_ENV missing (bootstrap must run first)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STAGE_ENV"
: "${AWS_REGION:?stage.env must set AWS_REGION}"

TMP_CADDY=""
TMP_OAUTH2=""
TMP_OPENCODE=""
cleanup() {
  [ -n "${TMP_CADDY:-}" ] && rm -f "$TMP_CADDY"
  [ -n "${TMP_OAUTH2:-}" ] && rm -f "$TMP_OAUTH2"
  [ -n "${TMP_OPENCODE:-}" ] && rm -f "$TMP_OPENCODE"
}
trap cleanup EXIT

# Appends one provider key to $TMP_OPENCODE. Called from provider-map.sh lines
# rendered by bootstrap (one `fetch_provider ENV PARAM` per entry).
fetch_provider() {
  env_name="$1"
  parameter_name="$2"
  [ -n "$parameter_name" ] || return 0
  provider_value=$(aws ssm get-parameter --name "$parameter_name" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")
  printf '%s=%s\n' "$env_name" "$provider_value" >> "$TMP_OPENCODE"
  unset provider_value
}

# Re-fetches all runtime secrets from SSM without tracing. Writes three
# per-service env files (ADR-0028): caddy.env, oauth2.env, opencode.env.
# Also the single manual rotation path (docs/credentials-rotation.md):
# update SSM, run `/usr/local/bin/opencode-secrets-refresh.sh` (a wrapper
# for `app.sh secrets`), then switch the backend color.
refresh_secrets() {
  set +x
  umask 077

  # --- caddy.env: DOMAIN + BASIC_AUTH ---
  TMP_CADDY=$(mktemp "$OPT_DIR/caddy.env.XXXXXX")
  printf 'DOMAIN=%s\n' "$DOMAIN" >> "$TMP_CADDY"
  VALUE=$(aws ssm get-parameter --name "$OPENCODE_PASSWORD_PARAMETER" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")
  BASIC=$(printf 'opencode:%s' "$VALUE" | base64 | tr -d '\n')
  printf 'BASIC_AUTH=%s\n' "$BASIC" >> "$TMP_CADDY" # pragma: allowlist secret -- derived from an SSM secret at runtime

  # --- opencode.env: password + provider API keys ---
  TMP_OPENCODE=$(mktemp "$OPT_DIR/opencode.env.XXXXXX")
  printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$VALUE" >> "$TMP_OPENCODE"
  unset VALUE BASIC

  if [ -f "$PROVIDER_MAP" ]; then
    # shellcheck disable=SC1090
    . "$PROVIDER_MAP"
  fi

  # --- oauth2.env: GitHub OAuth + cookie secret ---
  TMP_OAUTH2=$(mktemp "$OPT_DIR/oauth2.env.XXXXXX")
  printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' "$GITHUB_OAUTH_CLIENT_ID" >> "$TMP_OAUTH2"
  printf 'OAUTH2_PROXY_GITHUB_USERS=%s\n' "$GITHUB_OAUTH_USER" >> "$TMP_OAUTH2"
  printf 'OAUTH2_PROXY_REDIRECT_URL=https://%s/oauth2/callback\n' "$DOMAIN" >> "$TMP_OAUTH2"
  OAUTH_SECRET=$(aws ssm get-parameter --name "$GITHUB_OAUTH_SECRET_PARAMETER" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")
  printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$OAUTH_SECRET" >> "$TMP_OAUTH2"
  unset OAUTH_SECRET
  COOKIE_SECRET=$(aws ssm get-parameter --name "$OAUTH_COOKIE_SECRET_PARAMETER" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")
  printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "$COOKIE_SECRET" >> "$TMP_OAUTH2"
  unset COOKIE_SECRET

  # Atomically replace each env file (chmod before mv keeps the window secret-free).
  chmod 600 "$TMP_CADDY" "$TMP_OAUTH2" "$TMP_OPENCODE"
  mv -f "$TMP_CADDY"   "$OPT_DIR/caddy.env"
  mv -f "$TMP_OAUTH2"  "$OPT_DIR/oauth2.env"
  mv -f "$TMP_OPENCODE" "$OPT_DIR/opencode.env"
  TMP_CADDY=""
  TMP_OAUTH2=""
  TMP_OPENCODE=""
  trap - EXIT
}

git_setup() {
  set +x
  LIVE=$(cat "$OPT_DIR/.live-color" 2>/dev/null || echo blue)
  TARGET="opencode-$LIVE"
  for _ in $(seq 1 120); do
    $COMPOSE ps --status running --services 2>/dev/null | grep -q "^$TARGET$" && break
    sleep 5
  done
  # The backend installs git via apk inside its entrypoint (issue
  # #35): seconds after `up -d` the binary may not exist yet. Wait
  # for it instead of failing into a poisoned boot (Problem 2:
  # exec git raced the apk install and user_data exited non-zero).
  for _ in $(seq 1 60); do
    $COMPOSE exec -T "$TARGET" sh -c 'command -v git' >/dev/null 2>&1 && break
    sleep 2
  done
  $COMPOSE exec -T "$TARGET" sh -c 'command -v git' >/dev/null 2>&1 \
    || { echo "WARNING: git never appeared in $TARGET; skipping git setup" >&2; return 1; }
  GH_PAT=$(aws ssm get-parameter --name "$GITHUB_TOKEN_PARAMETER" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")
  [ -n "${GIT_USER_NAME:-}" ] && $COMPOSE exec -T "$TARGET" git config --global user.name "$GIT_USER_NAME" || true
  [ -n "${GIT_USER_EMAIL:-}" ] && $COMPOSE exec -T "$TARGET" git config --global user.email "$GIT_USER_EMAIL" || true
  $COMPOSE exec -T "$TARGET" git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GH_PAT" | $COMPOSE exec -T -i "$TARGET" sh -c 'cat > /root/.git-credentials && chmod 600 /root/.git-credentials' # pragma: allowlist secret
  unset GH_PAT
  # NOTE: `return`, never `exit` — callers invoke this as
  # `git_setup || echo WARNING`, and `exit` would bypass the `||`,
  # kill app.sh outright, and fail user_data/cloud-init with it.
  $COMPOSE exec -T "$TARGET" git config --global credential.helper | grep -q '^store$' || { echo "WARNING: git credential helper not applied" >&2; return 1; }
}

install_colors_service() {
  cat > /etc/systemd/system/opencode-colors.service <<'UNIT_EOF'
[Unit]
Description=Reconcile opencode blue-green colors after boot
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/opencode/switch.sh reconcile

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  # --now (issue #44): enable alone leaves the unit dormant until the
  # next reboot, so first boot ran both colors until then. Running
  # reconcile immediately stops whichever color is not live.
  systemctl enable --now opencode-colors.service
}

boot() {
  refresh_secrets
  cd "$OPT_DIR"
  # --no-deps: caddy depends_on both colors, so a plain up creates
  # blue and green in parallel against the same workspace volume and
  # the daemon can lose a mkdir race inside it, failing the whole up.
  # Green comes up later, serially, via the reconcile unit.
  docker compose up -d --no-deps caddy oauth2-proxy opencode-blue
  echo blue > "$OPT_DIR/.live-color"
  docker compose ps
  install_colors_service
  git_setup || echo "WARNING: git setup failed; re-run /opt/opencode/host/app.sh git-setup" >&2
}

refresh() {
  refresh_secrets
  git_setup || echo "WARNING: git setup failed; re-run /opt/opencode/host/app.sh git-setup" >&2
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-boot}" in
    boot) boot ;;
    refresh) refresh ;;
    secrets) refresh_secrets ;;
    git-setup) git_setup ;;
    *) echo "usage: $0 {boot|refresh|secrets|git-setup}" >&2; exit 1 ;;
  esac
fi
