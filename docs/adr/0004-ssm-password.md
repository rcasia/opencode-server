# ADR-0004: opencode Password from SSM SecureString

## Status

Accepted

## Date

2026-09-10

## Context

`opencode web` authenticates with HTTP basic auth (`OPENCODE_SERVER_PASSWORD`,
username `opencode`). The instance must obtain this password at boot without
it ever living in git, tfvars, CI logs, or Terraform state (state is
encrypted S3, but readable by anything with the deploy role — too broad).

## Decision Drivers

- **Must keep the secret out of git and state** — no password in committed
  files, variables, or `terraform output`.
- **Should keep setup to a one-time step** — no per-deploy secret juggling.
- **Should follow least privilege** — only the instance can read it, and
  only that one parameter.

## Considered Options

### Option 1: Committed or gitignored tfvars (rejected)

Committed = leaked. Gitignored = the pipeline (which has no repo-local
secrets) can't deploy — breaks ADR-0002's automatic deploys.

### Option 2: Terraform `random_password` + `aws_ssm_parameter` (rejected)

Puts the generated secret in Terraform state by design — fails the
must-have. Reading it back would also need extra plumbing.

### Option 3: Operator-created SecureString, name-only var (chosen)

The operator runs `aws ssm put-parameter --type SecureString` once.
Terraform only carries the parameter *name* (`/opencode/server-password`);
the instance role gets `ssm:GetParameter` on that ARN and nothing else; an
`ExecStartPre` script fetches the value into a `0600` env file under `/run`
at every service start.

- **Pros**: secret exists in exactly one place (SSM, KMS-encrypted);
  rotation is `put-parameter --overwrite` + service restart, no Terraform run.
- **Cons**: one manual step outside the pipeline (documented in README);
  a missing parameter fails the service at boot (loud, not silent).

### Option 4: Instance generates and stores its own password (rejected)

Needs `ssm:PutParameter` on the instance role and a way to show the operator
the generated value — more permissions and more plumbing than Option 3.

## Decision

We will store the opencode password in an **operator-created SSM
SecureString** and pass only its **name** through Terraform; the instance
fetches it at boot into a root-only runtime env file.

## Rationale

It is the only option that keeps the secret out of git, state, and logs
while adding exactly one documented manual step and one narrow IAM
permission.

## Consequences

### Positive

- `git log`, state files, and CI output are all safe to share.
- Rotation never touches Terraform.

### Negative

- First-time setup has an out-of-band step (mitigation: README checklist).
- Boot fails closed if the parameter is absent (accepted: better than
  starting unsecured — the service must never run without a password).

## Implementation Notes

- `modules/compute`: `aws_iam_role_policy` with `ssm:GetParameter` on
  `arn:aws:ssm:<region>:<account>:parameter<name>`; `user_data.sh` writes
  `/usr/local/bin/opencode-web-env.sh` + `opencode-web.service`
  (`EnvironmentFile=/run/opencode-web.env`).

## Related Decisions

- ADR-0001 (Caddy proxy; the password is the second layer behind TLS)
- ADR-0002 (automatic deploys — why gitignored tfvars can't work)
- ADR-0003 (secret hygiene)

## References

- [opencode Web authentication](https://opencode.ai/docs/web/#authentication)
- [AWS SSM SecureString](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-securestring.html)
