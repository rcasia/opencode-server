# opencode-server

[![ci](https://github.com/rcasia/opencode-server/actions/workflows/ci.yml/badge.svg)](https://github.com/rcasia/opencode-server/actions/workflows/ci.yml)

Terraform infra for an agentic coding EC2 server on AWS (`eu-west-1`, `t3.micro` default).

Provisions: VPC + public subnet + IGW, security group (SSH on your /32, Caddy 80/443), IAM role for SSM, EC2 (AL2023) with Docker + Node 22 + opencode web (systemd, localhost-only) behind Caddy with automatic Let's Encrypt TLS, Elastic IP.

## Layout

- `main.tf` — composes `modules/network` + `modules/compute`
- `modules/network` — VPC, subnet, IGW, routes, security group
- `modules/compute` — IAM role (SSM), optional key pair, EC2, EIP
- `bootstrap/` — one-time stack creating the S3 state bucket

## Usage (prod deploys automatically)

Push to `main` → `ci` checks, then the `deploy-prod` job in the same
run ships prod automatically (plan, apply, smoke test). There is no
manual step and no local apply against real AWS; local runs target
the Moto mock (see below).

```bash
git push origin main   # checks then deploy-prod, all in the ci run
```

`make plan-prod` works as a local pre-flight plan (needs credentials
plus `backend.hcl`). Without `AWS_ROLE_ARN` / `TF_STATE_BUCKET`
configured, `deploy-prod` fails red — that is the signal to finish the
one-time setup below.

## CI/CD pipeline

Deploys to prod run automatically, gated only by green checks —
designed after Fowler's [Continuous Integration](https://martinfowler.com/articles/continuousIntegration.html)
(see `AGENTS.md` for how each practice maps to this repo).

```text
push to main (PRs run the checks only, never deploy)
└─ ci, one workflow graph
     ├─ changes: paths-filter (infra vs pipeline vs docs-only)
     ├─ pre-commit: always (hygiene + terraform fmt/validate + actionlint + secrets)
     ├─ terraform: only on infra/pipeline changes (fmt -check, init, validate)
     ├─ local: only on infra/pipeline changes (moto plan, zero credentials)
     └─ deploy-prod (main pushes only, needs green-or-skipped checks)
          ├─ OIDC creds → init (S3) → validate → plan
          └─ apply + smoke test, only when the plan has changes
```
Gates fail open: if the filter breaks, everything runs. Docs-only pushes
skip `terraform`, `local`, and `deploy-prod` entirely.

- **Build once, ship that artifact.** `plan -out=tfplan` then `apply tfplan`
  — the exact reviewed plan is what ships. Kept as the `tfplan-prod`
  artifact (30 days) for audit.
- **Moto is the commit-stage double, not a prod clone.** Fast and
  credential-free, but a mock: the prod `plan` in the `deploy-prod` job
  is the gate that sees the real environment.
- **Release = merge.** No manual step; anything pushed to `main` must be
  shippable. Rollback = revert the commit and push — the next green run
  re-applies the previous state (state is versioned in S3).

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
7. Push to `main`; the `deploy-prod` job applies automatically
   (plan, apply, smoke test).

## GitHub Actions secrets and variables

`deploy-prod` needs two entries. If either is absent the run fails red —
by design, so missing config is visible instead of silent. Check
presence with:

```bash
gh secret list --repo rcasia/opencode-server
gh variable list --repo rcasia/opencode-server
```

| Name | Type | How to obtain |
|---|---|---|
| `AWS_ROLE_ARN` | Secret | One-time AWS setup above (pipeline steps 1–2): repo Settings → Secrets and variables → Actions → Secrets tab → New repository secret, paste the role ARN. |
| `TF_STATE_BUCKET` | Variable | After bootstrap apply: `terraform -chdir=bootstrap output -raw state_bucket`. Same Settings page → Variables tab → New repository variable. |

Also required before the first real apply (in code, not in Actions):
`allowed_ssh_cidr` in `environments/prod.tfvars` must be your IP with
`/32`, never `0.0.0.0/0`.

Connect:
```bash
# keyless (SSM)
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
# or SSH if ssh_public_key set
```

## opencode web access (phone-friendly HTTPS)

Design rationale lives in [`docs/adr/0001-caddy-tls-proxy.md`](docs/adr/0001-caddy-tls-proxy.md):
Caddy terminates TLS and proxies to `opencode web` on localhost; the login
password comes from an SSM SecureString parameter (never in repo/state).

One-time setup (from your laptop, needs AWS credentials):

```bash
# store the web password (username is `opencode`)
aws ssm put-parameter --region eu-west-1 --name /opencode/server-password \
  --type SecureString --value 'YOUR-STRONG-PASSWORD'
```

No DNS step needed: `domain_name` in `environments/prod.tfvars` uses
`nip.io` wildcard DNS (`54-170-161-9.nip.io` resolves to the EIP), and Caddy
gets a real Let's Encrypt certificate for it automatically.

Push to `main`; the pipeline replaces the instance (EIP and DNS survive).
After boot, open `https://54-170-161-9.nip.io` on your phone and log in as
`opencode`. If the EIP ever changes, update `domain_name` to match
(`<new-ip-with-dashes>.nip.io`).

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
