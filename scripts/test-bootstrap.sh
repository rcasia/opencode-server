#!/bin/bash
# Bootstrap test driver (ADR-0007): applies the mock stack, extracts the
# EXACT user_data the deploy would run, and builds app/Dockerfile.boot
# around it. Needs `make local-up` first (Moto backend). Mock-only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

curl -sf http://localhost:5000/moto-api/ >/dev/null || {
  echo "Moto is not up. Run 'make local-up' first."
  exit 1
}

echo "==> Applying mock stack (domain overridden for the test)"
terraform init -reconfigure -backend-config=environments/local.backend.hcl -input=false >/dev/null
# Compute only: Moto's CloudWatch mock returns malformed PutMetricAlarm
# responses, so the monitoring module can't apply locally. user_data needs
# only compute resources; full-config validity is covered by plan.
terraform apply -target=module.compute -var-file=environments/local.tfvars -var='domain_name=boot.test' -input=false -auto-approve >/dev/null

echo "==> Extracting rendered user_data + volume id from mock state"
VOLID="$(terraform show -json | python3 -c "
import json, sys
state = json.load(sys.stdin)
for mod in state['values']['root_module'].get('child_modules', []):
    if mod['address'] == 'module.compute':
        for res in mod.get('resources', []):
            if res['address'] == 'module.compute.aws_ebs_volume.data':
                print(res['values']['id'])
")"
[ -n "$VOLID" ] || { echo "volume id not found in mock state"; exit 1; }
terraform show -json | python3 -c "
import json, sys
state = json.load(sys.stdin)
for mod in state['values']['root_module'].get('child_modules', []):
    if mod['address'] == 'module.compute':
        for res in mod.get('resources', []):
            if res['address'] == 'module.compute.aws_instance.server':
                sys.stdout.write(res['values']['user_data'])
" > app/.rendered-user-data.sh
VOLSFX="$(echo "$VOLID" | tr -d '-')"
trap 'rm -f app/.rendered-user-data.sh' EXIT

# Registry cache: unchanged layers rebuild in seconds; changed tail re-runs.
# BOOT_TEST_CACHE=1 enables it (CI), BOOT_TEST_PUSH=1 publishes the image.
IMAGE="${BOOT_TEST_IMAGE:-ghcr.io/rcasia/opencode-boot-test}"
CACHE_ARGS=()
PUSH_ARGS=(-t opencode-boot-test)
if [ "${BOOT_TEST_CACHE:-0}" = "1" ]; then
  CACHE_ARGS=(--cache-from "type=registry,ref=$IMAGE:buildcache" --cache-to "type=registry,ref=$IMAGE:buildcache,mode=max")
fi
if [ "${BOOT_TEST_PUSH:-0}" = "1" ]; then
  PUSH_ARGS=(--push -t opencode-boot-test -t "$IMAGE:latest")
fi

echo "==> Building bootstrap test image (volume $VOLID)"
# (bash 3/macOS: empty-array expansion trips `set -u`, so scoped off here)
set +u
docker buildx build -f app/Dockerfile.boot "${CACHE_ARGS[@]}" "${PUSH_ARGS[@]}" \
  --build-arg "VOLSFX=$VOLSFX" --build-arg DOMAIN=boot.test .
set -u
echo "BOOTSTRAP TEST PASSED"
