# opencode-server

Terraform infra for an agentic coding EC2 server on AWS (`eu-west-1`, `t3.micro` default).

Provisions: VPC + public subnet + IGW, security group (SSH + opencode 4096), IAM role for SSM, EC2 (AL2023) with Docker + Node 22 + opencode via user-data, Elastic IP.

## Layout

- `main.tf` — composes `modules/network` + `modules/compute`
- `modules/network` — VPC, subnet, IGW, routes, security group
- `modules/compute` — IAM role (SSM), optional key pair, EC2, EIP
- `bootstrap/` — one-time stack creating the S3 state bucket

## Usage (prod deploys automatically)

Push to `main` → green `ci` → `deploy` runs automatically (Moto check,
plan, apply). There is no manual step and no local apply against real
AWS; local runs target the Moto mock (see below).

```bash
git push origin main   # ci must go green; deploy follows on its own
```

`make plan-prod` works as a local pre-flight plan (needs credentials
plus `backend.hcl`). Until `AWS_ROLE_ARN` is configured, deploy jobs
skip instead of failing.

## Pipeline setup (one-time, AWS console)

Deploys use OIDC — no long-lived access keys.

1. IAM → Identity providers → Add OIDC provider: URL
   `https://token.actions.githubusercontent.com`, audience
   `sts.amazonaws.com`.
2. IAM → Roles → Create role → Web identity: pick that provider, audience
   `sts.amazonaws.com`, condition `StringLike`
   `token.actions.githubusercontent.com:sub` =
   `repo:rcasia/opencode-server:*`. Name it `opencode-server-deploy`.
3. Attach a policy covering: EC2/VPC/SG/EIP/key-pair/volume management,
   IAM roles + instance profiles + key pairs + attaching the
   `AmazonSSMManagedInstanceCore` policy, and S3 access to the state
   bucket (`s3:ListBucket` on the bucket, object RW on
   `opencode-server/*`).
4. Deploy `bootstrap/` once (creates the state bucket) and note its name.
5. GitHub → repo Settings → Secrets and variables → Actions:
   - Secret `AWS_ROLE_ARN` = the role ARN from step 2.
   - Variable `TF_STATE_BUCKET` = the state bucket name from step 4.
6. Restrict `allowed_ssh_cidr` in `environments/prod.tfvars` to your
   IP with `/32` — never deploy prod open to `0.0.0.0/0`.
7. Dispatch a plan first, review it, then dispatch apply.

Connect:
```bash
# keyless (SSM)
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
# or SSH if ssh_public_key set
```

## Fully local deploy (Moto)

Docker running, no AWS credentials, no pip install. Everything runs
against a Moto mock container:

```bash
make local-up      # start mock + state bucket + register placeholder AMI
make plan-local    # init + fmt + validate + plan against the mock
make apply-local   # deploy to the mock
make destroy-local # teardown
make local-down    # stop the mock
```

Notes: `aws_endpoint_url` switches the provider, backend, and lookups to
the mock. `make local-up` writes the mock AMI id to
`environments/local.auto.tfvars.json` (generated, gitignored) because Moto
only boots registered images. Outputs (IPs, ids) are mock values.

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
