# AGENTS.md — opencode-server

Terraform repo for a single EC2 agentic coding server on AWS.
Defaults: region `eu-west-1`, instance `t3.micro`, AL2023, single public
subnet (no NAT), Elastic IP, SSM access, optional SSH key.

## Structure

- `versions.tf` — terraform + AWS provider pins, default tags
- `variables.tf` — region, project, environment, instance_type,
  allowed_ssh_cidr, ssh_public_key, root_volume_size, opencode_port
- `main.tf` — VPC, subnet, IGW, routes, SG (22 + opencode port),
  IAM role for SSM, optional key pair, EC2, EIP
- `outputs.tf` — instance_id, public_ip, vpc/sg ids, ssh/ssm commands
- `user_data.sh` — bootstrap: docker, Node 22, opencode
- `terraform.tfvars.example` — copy to `terraform.tfvars` (gitignored)
- `.pre-commit-config.yaml` — file hygiene + terraform_fmt + terraform_validate
- `.github/workflows/ci.yml` — jobs `pre-commit` and `terraform`

## Required skills

Load these before changing infra:

- `terraform` — file layout (main/variables/outputs/versions),
  `fmt -recursive`, `validate`, plan-before-apply, remote-state notes,
  least-privilege IAM, `for_each` over `count`, tag everything.
- `aws` — EC2/SSM/VPC/SG posture: no `0.0.0.0/0` in prod, encrypted EBS,
  SSM (`AmazonSSMManagedInstanceCore`) preferred over long-lived SSH keys,
  egress-only SG plus explicit ingress, cost notes (t3.micro, gp3, EIP
  attached).

## Rules

1. Atomic conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`).
   One concern per commit; never mix infra + CI + docs.
2. Always run `pre-commit run` on staged changes and rely on its outcome.
   If it fails, fix and re-stage — never bypass with `--no-verify`.
3. Always rely on GitHub Actions outcome after push (`gh run watch`).
   `pre-commit` and `terraform` jobs must both be green.
4. Never commit state or secrets: no `*.tfstate*`, no `terraform.tfvars`,
   no private keys. `ssh_public_key` stays empty unless needed; prefer SSM.
5. `terraform fmt -recursive` and `terraform validate` must pass locally
   before push. CI runs `fmt -check`, `init -backend=false`, `validate`.
6. Plan before apply. Never `apply -auto-approve` locally; review the plan.
   Never `destroy` without explicit user confirmation.
7. Security defaults: restrict `allowed_ssh_cidr` to `YOUR_IP/32`,
   keep EBS encrypted, keep provider pin `~> 5.0`, keep default tags
   (`Project`, `Environment`, `ManagedBy`).
8. Cheap by design: single AZ public subnet, no NAT gateway, EIP attached
   to the instance. Call out any change that adds recurring cost.

## Workflows

```bash
cp terraform.tfvars.example terraform.tfvars  # set allowed_ssh_cidr
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Connect:

```bash
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
```

Checks:

```bash
pre-commit run --all-files
gh run list --repo rcasia/opencode-server --limit 5
gh run watch <run-id> --repo rcasia/opencode-server
```
