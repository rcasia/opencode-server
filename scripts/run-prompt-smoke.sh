#!/bin/bash
# Run the host prompt smoke through SSM and preserve bounded output for CI.
set -euo pipefail

INSTANCE_ID="${1:?usage: $0 INSTANCE_ID [DEPLOYED_REF]}"
DEPLOYED_REF="${2:-unknown}"
ARTIFACT_DIR="${ARTIFACT_DIR:-smoke-artifacts}"
mkdir -p "$ARTIFACT_DIR"
LOG="$ARTIFACT_DIR/prompt-smoke.log"
: >"$LOG"

PARAMETERS="$(jq -cn --arg command "cd /opt/opencode && host/prompt-smoke.sh edge '$DEPLOYED_REF'" '{commands: [$command]}')"
if ! COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --timeout-seconds 120 \
  --parameters "$PARAMETERS" \
  --query Command.CommandId \
  --output text 2>"$ARTIFACT_DIR/send-command-error.log")"; then
  { echo "send-command failed for $INSTANCE_ID"; cat "$ARTIFACT_DIR/send-command-error.log"; } | tee "$LOG" >&2
  exit 1
fi
echo "SSM prompt smoke CommandId: $COMMAND_ID on $INSTANCE_ID"

STATUS=Pending
for _ in $(seq 1 30); do
  STATUS="$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in Success | Failed | Cancelled | TimedOut) break ;; esac
  sleep 5
done

{
  echo "command_id=$COMMAND_ID"
  echo "instance_id=$INSTANCE_ID"
  echo "deployed_ref=$DEPLOYED_REF"
  echo "status=$STATUS"
  echo "--- stdout ---"
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text 2>/dev/null || true
  echo "--- stderr ---"
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text 2>/dev/null || true
} | tee "$LOG"

[ "$STATUS" = "Success" ]
