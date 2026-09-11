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
     ├─ changes: paths-filter (infra vs app vs pipeline vs docs-only)
     ├─ pre-commit: always (hygiene + terraform fmt/validate + actionlint + secrets)
     ├─ terraform: only on infra/pipeline changes (fmt -check, init, validate)
     ├─ local: only on infra/pipeline changes (moto plan + apply + idempotence)
     ├─ bootstrap (main pushes only, needs green-or-skipped checks)
     │    └─ adopts + applies bootstrap/ (deploy trust) via OIDC itself
     ├─ deploy-prod (main pushes only, needs bootstrap)
     │    ├─ upload app bundle → OIDC creds → init (S3) → validate → plan
     │    └─ apply + smoke test, only when the plan has changes
     └─ deploy-app (app-file changes only, after deploy-prod)
          └─ SSM rolling restart (pull + up, no replacement) + smoke test
```
App changes never replace the instance: the bundle (`app/`) uploads to S3
and the live box pulls + restarts containers (seconds of blip). Host
changes (Terraform) still replace — rarely, by construction. Rationale:
[`docs/adr/0011-rolling-deploys.md`](docs/adr/0011-rolling-deploys.md).
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

## Pipeline setup (one-time bridge, then pipeline owns everything)

Deploys use OIDC — no long-lived access keys. Standing rule: **prod is
pipeline-only, no laptop touches** — bootstrap included (see
[`docs/adr/0013-pipeline-bootstrap.md`](docs/adr/0013-pipeline-bootstrap.md)).
The role, OIDC provider, and state bucket already exist manually; the
pipeline adopts them. It needs one hand-made bridge first:

IAM → Roles → `opencode-server-deploy` → Add inline policy named
`bridge` with the statements listed in ADR-0013 (bundle + state bucket
management, scoped IAM self-management, `sts:GetCallerIdentity`).

Then push: the `bootstrap` job imports the manual resources, applies
`bootstrap/` (creating the TF-managed policy), and deletes the `bridge`
policy. From that point the role carries exactly what Terraform says —
no residue.

After that:

1. GitHub → repo Settings → Secrets and variables → Actions:
   - Secret `AWS_ROLE_ARN` = the deploy role ARN (unchanged by adoption).
   - Variable `TF_STATE_BUCKET` = the state bucket name.
2. Restrict `allowed_ssh_cidr` in `environments/prod.tfvars` to your
   IP with `/32` — never deploy prod open to `0.0.0.0/0`.
3. Push to `main`; `bootstrap` then `deploy-prod` apply automatically
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
| `AWS_ROLE_ARN` | Secret | `terraform -chdir=bootstrap output -raw deploy_role_arn` (pipeline setup above): repo Settings → Secrets and variables → Actions → Secrets tab → New repository secret, paste the role ARN. |
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

Which version is live: every apply stamps the commit SHA as the
`DeployedRef` tag on the instance and data disk (EC2 console → Tags) and
in the `deployed_version` output. Compare with `git log --oneline -1` —
same SHA means prod matches your checkout. App image versions ride along:
they're pinned in `app/compose.yaml` at that commit.

## App stack (compose, testable locally)

Caddy + opencode run as containers from `app/compose.yaml` (images pinned
`tag@digest`, bumped by Dependabot). Rationale:
[`docs/adr/0007-compose-deployment.md`](docs/adr/0007-compose-deployment.md).

```bash
make test-boot   # full chain locally: compose up, HTTPS, 401 without creds, 200 with
make test-bootstrap  # executes the exact rendered user_data in AL2023 (needs local-up)
```

`test-boot` uses dummy env (never committed) and tears everything down
afterwards. It proves installs, config, proxy, and auth — everything except
Let's Encrypt issuance, which needs the public IP.

`test-bootstrap` covers the other layer: it applies the mock stack, extracts
the exact `user_data` Terraform would run, and executes it in an AL2023
container (`app/Dockerfile.boot`) with only cloud endpoints stubbed
(SSM, systemd, mount, Docker daemon). Catches script bugs deterministically;
EC2-only races (attach timing) still need the real box. It runs locally
only — deliberately not in the pipeline (too slow); run it via `make`
when changing `user_data.sh`.

Speed: the Dockerfile builds in two stages — `bootenv` (all installs,
published to GHCR, rebuilt rarely) and `test` (the script, re-runs in a
few minutes). Registry layer caching means unchanged inputs rebuild in
seconds, locally and in CI. First pull creates the `opencode-boot-test`
package — set it private.

Images stay pinned `tag@digest` in `app/compose.yaml`. Dependabot's
`docker-compose` ecosystem proposes bumps (same 21-day cooldown policy);
merge with `make test-boot` green. Manual fallback:

```bash
docker pull caddy:2.12-alpine   # then copy the printed digest
docker pull ghcr.io/anomalyco/opencode:1.19.0
# update the two image: lines, then prove it:
make test-boot
```

State survives deploys: a persistent 10 GB encrypted EBS disk is mounted at
`/var/lib/docker`, so sessions, config, workspace, images, and certs live
through instance replacement (see
[`docs/adr/0008-data-volume.md`](docs/adr/0008-data-volume.md)). Only a full
`terraform destroy` wipes it.

## Intrusion alerts

Port 443 is public by design, so scanners will knock. Caddy access logs and
sshd logs ship to CloudWatch; alarms email you on login probing (≥20 HTTP
401s in 5 min) or SSH probing (≥3 failures in 5 min). Rationale:
[`docs/adr/0006-intrusion-alerting.md`](docs/adr/0006-intrusion-alerting.md).
Cost is cents per month (log ingestion + 2 alarms).

Setup: set the `ALERT_EMAIL` Actions variable (repo Settings → Secrets
and variables → Actions → Variables tab), push, then click the SNS
confirmation email (subscription stays `PendingConfirmation` until you do
— no emails before that).

Uptime is watched separately: Route 53 probes the unauthenticated
`/ping` every 30s and pages after 3 failures (~$0.50/mo). Probes never
touch opencode, so they stay out of the login-failure metric.

## Git on the server (commits + push)

Identity comes from `git_user_name` / `git_user_email` (already set in
`environments/prod.tfvars`). Auth needs a Personal Access Token:

```bash
# 1. GitHub → Settings → Developer settings → Personal access tokens →
#    Fine-grained token, contents read/write on your repos, no admin.
# 2. store it (shown once — copy immediately)
aws ssm put-parameter --region eu-west-1 --name /opencode/github-token \
  --type SecureString --value 'YOUR-TOKEN'
```

The boot helper (`/usr/local/bin/opencode-git-setup.sh`) fetches it and
configures the container automatically on next deploy. To apply without a
deploy, or after rotating the token, re-run it on the host:

```bash
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
/usr/local/bin/opencode-git-setup.sh
```

Rationale: [`docs/adr/0010-git-auth.md`](docs/adr/0010-git-auth.md).

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
Bootstrap state lives there too (`opencode-server/bootstrap/terraform.tfstate`),
managed by the `bootstrap` CI job — both backends init with
`-backend=false` in pre-commit, so no bucket or credentials are needed there.

Local `backend.hcl` flow (root stack, read-only pre-flight): copy
`backend.hcl.example` to `backend.hcl` (gitignored), fill the bucket,
`terraform init -backend-config=backend.hcl`. Plan only (`make
plan-prod`) — applies ship via the pipeline, never from a laptop.
