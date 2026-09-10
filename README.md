# opencode-server

Terraform infra for an agentic coding EC2 server on AWS (`eu-west-1`, `t3.micro` default).

Provisions: VPC + public subnet + IGW, security group (SSH + opencode 4096), IAM role for SSM, EC2 (AL2023) with Docker + Node 22 + opencode via user-data, Elastic IP.

## Layout

- `main.tf` — composes `modules/network` + `modules/compute`
- `modules/network` — VPC, subnet, IGW, routes, security group
- `modules/compute` — IAM role (SSM), optional key pair, EC2, EIP
- `bootstrap/` — one-time stack creating the S3 state bucket

## Usage (local = staging)

Local runs deploy to staging via `environments/staging.tfvars`:

```bash
make plan-staging   # init + fmt + validate + plan staging
make apply-staging  # init + apply staging
```

Or raw terraform:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var-file=environments/staging.tfvars
terraform apply -var-file=environments/staging.tfvars
```

Custom one-off vars (gitignored):

```bash
cp terraform.tfvars.example terraform.tfvars
# edit allowed_ssh_cidr to YOUR_IP/32
terraform plan -var-file=terraform.tfvars
```

Connect:
```bash
# keyless (SSM)
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
# or SSH if ssh_public_key set
```

## State backend (S3)

Root state lives in S3 with native locking (`use_lockfile`, no DynamoDB).
One-time bootstrap from your laptop:

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
cp backend.hcl.example backend.hcl  # fill bucket from bootstrap output
terraform init -migrate-state -backend-config=backend.hcl
```

`backend.hcl` is gitignored. CI and pre-commit init with `-backend=false`,
so no bucket or credentials are needed there.
