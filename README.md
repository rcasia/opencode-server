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

Without `AWS_ROLE_ARN` / `TF_STATE_BUCKET` configured, `deploy-prod`
fails red — that is the signal to finish the one-time setup below.
Review the `tfplan-prod` artifact in the run, never plan from a laptop.

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
           └─ SSM blue-green switch (idle color up, /ready-gated, no replacement) + smoke test
```
App changes never replace the instance: the bundle (`app/`) uploads to S3
and the live box starts the idle backend color, waits for its `/ready`,
then stops the live color — no failed requests, and a bad release aborts
with live untouched. Host changes (Terraform) still replace — rarely, by
construction. Rationale:
[`docs/adr/0015-blue-green-ready-gate.md`](docs/adr/0015-blue-green-ready-gate.md)
(supersedes the rolling restart in
[`docs/adr/0011-rolling-deploys.md`](docs/adr/0011-rolling-deploys.md)).
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
| `AWS_ROLE_ARN` | Secret | The deploy role ARN from the one-time setup (pipeline adoption never changes it): repo Settings → Secrets and variables → Actions → Secrets tab → New repository secret. |
| `TF_STATE_BUCKET` | Variable | The state bucket name (`opencode-prod-tfstate-<account-id>`). Same Settings page → Variables tab → New repository variable. |
| `DOMAIN_NAME` | Secret | The public hostname (your `<eip-with-dashes>.nip.io`); overrides the `code.example.com` placeholder in `prod.tfvars` via `TF_VAR_domain_name`. |
| `GITHUB_OAUTH_CLIENT_ID` | Secret | Client ID of your GitHub OAuth App; overrides the empty placeholder via `TF_VAR_github_oauth_client_id`. |
| `GITHUB_OAUTH_USER` | Secret | The one GitHub username allowed through SSO; overrides the empty placeholder via `TF_VAR_github_oauth_user`. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | Secrets | Agent commit identity; override the empty placeholders via `TF_VAR_git_user_name` / `TF_VAR_git_user_email`. |

Also required before the first real apply (in code, not in Actions):
`allowed_ssh_cidr` in `environments/prod.tfvars` must be your IP with
`/32`, never `0.0.0.0/0`.

Shell access: there is none from laptops — no SSH keys issued, no SSM
shells. The server is operated through `opencode web` (the
`opencode_url` output, user `opencode`) and through the pipeline. A
suspect box is recovered by re-running the deploy jobs, not by logging
in; the data volume survives replacement.

## opencode web access (phone-friendly HTTPS, passwordless SSO)

Design rationale lives in [`docs/adr/0001-caddy-tls-proxy.md`](docs/adr/0001-caddy-tls-proxy.md)
and [`docs/adr/0014-github-sso-oauth2-proxy.md`](docs/adr/0014-github-sso-oauth2-proxy.md):
Caddy terminates TLS and gates every browser route (except `/ping` and
`/ready`) on
GitHub SSO via oauth2-proxy (single-user allowlist); the opencode backend
password stays machine-only — Caddy injects it after SSO, so you never
type a shared password. `/ready` is the public readiness gate (200
`"ready"` only while a backend color answers; bodies masked) used by
deploys and the uptime probe.

One-time setup (from your laptop, needs AWS credentials):

```bash
# 1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App:
#    Homepage URL https://<domain>, callback https://<domain>/oauth2/callback.
#    Store the Client ID in the GITHUB_OAUTH_CLIENT_ID repo secret and your
#    username in GITHUB_OAUTH_USER (never in git — the tfvars placeholders
#    fail closed).
# 2. store the client secret (shown once — copy immediately)
aws ssm put-parameter --region eu-west-1 --name /opencode/github-oauth-secret \
  --type SecureString --value 'YOUR-OAUTH-CLIENT-SECRET'

# 3. mint the session cookie secret (32-byte base64url, never in git)
openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '\n' | \
  xargs -I{} aws ssm put-parameter --region eu-west-1 \
    --name /opencode/oauth-cookie-secret --type SecureString --value '{}'

# 4. keep the backend password too (machine-only, human never types it)
aws ssm put-parameter --region eu-west-1 --name /opencode/server-password \
  --type SecureString --value 'YOUR-STRONG-PASSWORD'
```

Then set the `DOMAIN_NAME`, `GITHUB_OAUTH_CLIENT_ID`, and
`GITHUB_OAUTH_USER` repo secrets and push to `main`.

Rotating later: [`docs/credentials-rotation.md`](docs/credentials-rotation.md)
(overwrite the parameter + one SSM command, no Terraform run).

No DNS step needed: `domain_name` defaults to the `code.example.com`
placeholder and the operator overrides it with the `DOMAIN_NAME` secret
holding `<eip-with-dashes>.nip.io` (wildcard DNS resolves it to the EIP),
and Caddy gets a real Let's Encrypt certificate for it automatically.

Push to `main`; the pipeline replaces the instance (EIP and DNS survive).
After boot, open `https://<your-eip-with-dashes>.nip.io` on your phone and
log in with GitHub (single allowed user). If the EIP ever changes, update
the `DOMAIN_NAME` secret to match (`<new-ip-with-dashes>.nip.io`) — and
update the OAuth App callback URL to `https://<new-domain>/oauth2/callback`.

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
make test-boot   # full chain locally: compose up, HTTPS, 302 SSO gate, /ready,
                 # then a blue-green switch rehearsal sampled for any failed request
```

`test-boot` uses dummy env (never committed, dummy OAuth values — proves
SSO wiring, not the GitHub round-trip) and tears everything down
afterwards. It proves installs, config, proxy, and auth — everything except
Let's Encrypt issuance, which needs the public IP. `user_data.sh` changes
are proven by shellcheck plus real deploys (the instance is cattle and the
smoke test gates); the old AL2023-execution test was removed — measured
~11 min cached, never worth running (see ADR-0007 amendment 4).

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
sshd logs ship to CloudWatch; alarms email you on SSO probing (≥20 HTTP
403s in 5 min), backend login probing (≥20 HTTP 401s in 5 min), or SSH
probing (≥3 failures in 5 min). Rationale:
[`docs/adr/0006-intrusion-alerting.md`](docs/adr/0006-intrusion-alerting.md).
Cost is cents per month (log ingestion + 2 alarms).

Setup: set the `ALERT_EMAIL` Actions secret (repo Settings → Secrets
and variables → Actions → Secrets tab, so the address is masked in logs), push, then click the SNS
confirmation email (subscription stays `PendingConfirmation` until you do
— no emails before that).

Uptime is watched separately: Route 53 probes the public `/ready` gate
every 30s and pages after 3 failures (~$0.50/mo) — full chain (edge +
backend), so app failure pages too. Probes bypass SSO, so they stay out
of the login-failure metric.

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
configures the container at every boot. Rotating the token takes effect
on the next deploy — token values never touch the repo or the pipeline.
Full procedure (verify-before-revoke order):
[`docs/credentials-rotation.md`](docs/credentials-rotation.md).

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

Root + bootstrap state live in S3 with native locking (`use_lockfile`,
no DynamoDB), managed by the pipeline only. Laptops never init real
backends and never read prod state — review the `tfplan-prod` artifact
and job logs instead.

## Rebuilding from zero

If everything (including state) is destroyed, one AWS admin with
console access performs the seeds below. Everything else ships via the
pipeline — there is intentionally no laptop path back.

Have ready up front:

- AWS account id, and a user who can create IAM roles, S3 buckets, and
  SSM parameters.
- This repo, with `environments/prod.tfvars` filled (`allowed_ssh_cidr`
  as your `/32`). Leave `domain_name` empty on the first pass — the EIP
  is not known yet.
- Four secret values (never in git): a strong opencode password, a
  GitHub personal access token, a GitHub OAuth App client secret, and a
  32-byte oauth cookie secret.
- The OIDC subject in `bootstrap/variables.tf` (`deploy_subject`) — it
  is committed; EMU orgs need the numeric form, no slug pattern.
- The bridge policy JSON in
  [`docs/adr/0013-pipeline-bootstrap.md`](docs/adr/0013-pipeline-bootstrap.md).

Steps:

1. Console: create S3 bucket `opencode-prod-tfstate-<account>` with
   versioning enabled. (The pipeline adopts it; the backend needs the
   bucket to exist before the first init.)
2. Console: create the GitHub OIDC provider
   (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`)
   and the `opencode-server-deploy` role with strict trust: `StringEquals`
   on `aud` = `sts.amazonaws.com`, `sub` = the committed
   `deploy_subject`, `ref` = `refs/heads/main`.
3. Console: attach the inline `bridge` policy from ADR-0013 to the role.
4. Repo Settings → Secrets and variables → Actions: `AWS_ROLE_ARN`
   secret (the role ARN), `TF_STATE_BUCKET` variable (the bucket name),
   optional `ALERT_EMAIL` secret.
5. Seed the SSM SecureStrings `/opencode/server-password`,
   `/opencode/github-token`, `/opencode/github-oauth-secret`, and
   `/opencode/oauth-cookie-secret` (console or any admin machine —
   values only, Terraform never manages secret values). Create the GitHub
   OAuth App first (callback `https://<domain>/oauth2/callback` once the
   domain is known — step 7; use a placeholder and fix it then).
6. Push to `main`: `bootstrap` adopts the bucket/role/provider, converges
   the managed policy, and deletes `bridge`; `deploy-prod` then builds
   everything. Read the new EIP from the `terraform output` step log.
7. Set the `DOMAIN_NAME` repo secret to `<eip-with-dashes>.nip.io`
   (read from the `terraform output` step log) and push again. The instance
   is replaced (EIP and data volume survive); Caddy issues TLS and the
   smoke test expects the 302 SSO gate.
8. Click the SNS subscription confirmation email.

Permanently manual: the two SSM secret values and the SNS confirmation
click. Everything else — including this runbook's own trust — is code.

## Out-of-band host / missing EBS volumes

The host is cattle (`user_data_replace_on_change = true`): any user_data
change (new commit SHA in tags is not one, but domain/secret-path/volume
wiring changes are) replaces the instance, and the old root volume is
deleted with it. The separate data disk (`aws_ebs_volume.data`) survives
by design. Consequences an operator will meet in the console:

- Viewing a terminated instance's Storage tab fails to describe its old
  root volume — expected, not an error to fix. Note the volume ID and
  move on.
- `Failed to describe` on the **data** volume ID means it was deleted
  outside Terraform (nothing in this repo deletes it: no literal volume
  IDs exist in git, and the pipeline plan never destroys
  `module.compute.aws_ebs_volume.data`). Treat it as a data-loss /
  state-drift event, never as a prompt to re-apply blindly.

Verify from any admin machine (read-only; do not run writes from here):

```bash
aws ec2 describe-instances --region eu-west-1 \
  --instance-ids i-01f46c22f45ca3244 \
  --query 'Reservations[].Instances[].[State.Name,InstanceType,SubnetId,BlockDeviceMappings]'
aws ec2 describe-volumes --region eu-west-1 \
  --filters Name=tag:Project,Values=opencode \
  --query 'Volumes[].[VolumeId,State,AvailabilityZone,Size,Attachments]'
aws ec2 describe-snapshots --region eu-west-1 --owner-ids self \
  --query 'Snapshots[].[SnapshotId,VolumeId,StartTime,State]'
```

Reconcile only after the three reads agree on what is live:

- If the running host is hand-built and expendable: terminate it in the
  console, then push an empty commit. The next `deploy-prod` plan creates
  a fresh host + fresh (empty) data disk and re-attaches the EIP. The
  plan must show `aws_ebs_volume.data` created, never destroyed.
- If the running host holds state worth keeping: do NOT import it as
  `module.compute.aws_instance.server` and re-apply — the user_data diff
  would schedule the host's own replacement. Snapshot its disks first,
  then decide (adopt vs. cut over) with the snapshot IDs in hand.
- Never `terraform state rm` the volume or attachment to "clear" the
  error: that orphans the decision the next plan has to make. Remove
  stale entries only for resources confirmed terminated/deleted, and only
  via the pipeline workspace, never a laptop backend.
