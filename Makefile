.PHONY: help init fmt validate plan-staging apply-staging destroy-staging pre-commit

TF_VARS := environments/staging.tfvars
BACKEND_CFG := $(wildcard backend.hcl)
BACKEND_ARG := $(if $(BACKEND_CFG),-backend-config=backend.hcl)

help:
	@echo "Targets: init | fmt | validate | plan-staging | apply-staging | destroy-staging | pre-commit"
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
