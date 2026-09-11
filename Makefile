.PHONY: help fmt validate pre-commit local-up local-down plan-local apply-local destroy-local test-boot

# All terraform runs happen inside infra/ (-chdir); the root stack
# (infra/*.tf, infra/modules/*, infra/environments/*) is the only
# local target — bootstrap/ and prod ship via the pipeline only.
TF := terraform -chdir=infra

LOCAL_VARS := environments/local.tfvars
LOCAL_BACKEND := environments/local.backend.hcl
LOCAL_BUCKET := opencode-local-tfstate
MOTO_PORT := 5000
MOTO_ENDPOINT := http://localhost:$(MOTO_PORT)

help:
	@echo "Targets: fmt | validate | pre-commit"
	@echo "         local-up | local-down | plan-local | apply-local | destroy-local"
	@echo "         test-boot (full-chain local test of app/ via compose, dummy env)"
	@echo "Prod is pipeline-only (no reads either): no plan, apply, or backend init from a laptop."

fmt:
	terraform fmt -recursive

validate:
	$(TF) init -backend=false -input=false
	$(TF) validate

pre-commit:
	pre-commit run --all-files

local-up:
	docker compose up -d moto
	@echo "Waiting for moto at $(MOTO_ENDPOINT)..."
	@for i in $$(seq 1 30); do curl -sf $(MOTO_ENDPOINT)/moto-api/ >/dev/null && break || sleep 1; done
	AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=$(MOTO_ENDPOINT) --region eu-west-1 s3 mb s3://$(LOCAL_BUCKET) 2>/dev/null || true
	AMI_ID=$$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=$(MOTO_ENDPOINT) --region eu-west-1 ec2 register-image --name opencode-local-ami --architecture x86_64 --query ImageId --output text) && echo "{\"ami_id\": \"$$AMI_ID\"}" > infra/environments/local.auto.tfvars.json
	@echo "Local AMI ready: `cat infra/environments/local.auto.tfvars.json`"

local-down:
	docker compose down

plan-local:
	$(TF) init -reconfigure -backend-config=$(LOCAL_BACKEND) -input=false
	terraform fmt -recursive
	$(TF) validate
	$(TF) plan -var-file=$(LOCAL_VARS) -input=false

apply-local:
	$(TF) init -reconfigure -backend-config=$(LOCAL_BACKEND) -input=false
	$(TF) apply -var-file=$(LOCAL_VARS)

destroy-local:
	$(TF) destroy -var-file=$(LOCAL_VARS)

test-boot:
	./scripts/test-boot.sh
