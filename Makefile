.PHONY: help init fmt validate plan-staging apply-staging destroy-staging pre-commit local-up local-down plan-local apply-local destroy-local

TF_VARS := environments/staging.tfvars
BACKEND_CFG := $(wildcard backend.hcl)
BACKEND_ARG := $(if $(BACKEND_CFG),-backend-config=backend.hcl)

LOCAL_VARS := environments/local.tfvars
LOCAL_BACKEND := environments/local.backend.hcl
LOCAL_BUCKET := opencode-local-tfstate
MOTO_PORT := 5000
MOTO_ENDPOINT := http://localhost:$(MOTO_PORT)
MOTO_PID := .moto.pid
MOTO_LOG := .moto.log

help:
	@echo "Targets: init | fmt | validate | plan-staging | apply-staging | destroy-staging | pre-commit"
	@echo "         local-up | local-down | plan-local | apply-local | destroy-local"
	@echo "Local == staging: local runs deploy to staging via $(TF_VARS)."

init:
	terraform init -input=false $(BACKEND_ARG)

fmt:
	terraform fmt -recursive

validate:
	terraform init -backend=false -input=false
	terraform validate

plan-staging:
	terraform init -input=false $(BACKEND_ARG)
	terraform fmt -recursive
	terraform validate
	terraform plan -var-file=$(TF_VARS) -input=false

apply-staging:
	terraform init -input=false $(BACKEND_ARG)
	terraform apply -var-file=$(TF_VARS)

destroy-staging:
	@echo "Refusing without confirmation. Run:"
	@echo "  terraform destroy -var-file=$(TF_VARS)"

pre-commit:
	pre-commit run --all-files

local-up:
	@curl -sf $(MOTO_ENDPOINT)/moto-api/ >/dev/null 2>&1 || (MOTO_IAM_LOAD_MANAGED_POLICIES=true nohup python3 -m moto.server -p$(MOTO_PORT) > $(MOTO_LOG) 2>&1 & echo $$! > $(MOTO_PID))
	@echo "Waiting for moto at $(MOTO_ENDPOINT)..."
	@for i in $$(seq 1 30); do curl -sf $(MOTO_ENDPOINT)/moto-api/ >/dev/null && break || sleep 1; done
	AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=$(MOTO_ENDPOINT) --region eu-west-1 s3 mb s3://$(LOCAL_BUCKET) 2>/dev/null || true
	AMI_ID=$$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=$(MOTO_ENDPOINT) --region eu-west-1 ec2 register-image --name opencode-local-ami --architecture x86_64 --query ImageId --output text) && echo "{\"ami_id\": \"$$AMI_ID\"}" > environments/local.auto.tfvars.json
	@echo "Local AMI ready: `cat environments/local.auto.tfvars.json`"

local-down:
	@if [ -f $(MOTO_PID) ]; then kill `cat $(MOTO_PID)` 2>/dev/null || true; rm -f $(MOTO_PID); fi

plan-local:
	terraform init -reconfigure -backend-config=$(LOCAL_BACKEND) -input=false
	terraform fmt -recursive
	terraform validate
	terraform plan -var-file=$(LOCAL_VARS) -input=false

apply-local:
	terraform init -reconfigure -backend-config=$(LOCAL_BACKEND) -input=false
	terraform apply -var-file=$(LOCAL_VARS)

destroy-local:
	terraform destroy -var-file=$(LOCAL_VARS)
