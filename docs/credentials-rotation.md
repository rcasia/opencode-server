# Credential rotation

All secrets live in SSM SecureStrings (never in git, tfvars, images, or
Terraform state — see ADR-0004, ADR-0010). Rotation never touches
Terraform: overwrite the parameter, then make the running box pick it up.

Conventions below: region `eu-west-1`, parameters `/opencode/server-password`
and `/opencode/github-token`, instance tagged `opencode-prod-server`.
The `aws` commands run from any admin machine with AWS access (same access
as the initial seeding in the README). Never `echo` a secret value, never
paste one into a GitHub issue, workflow log, or chat.

## Inventory

| Credential | Lives in | Read by | Rotation | Picks up |
|---|---|---|---|---|
| opencode web password (`opencode` user) | SSM `/opencode/server-password` | instance role, at boot → `/opt/opencode/app.env` (0600) | `put-parameter --overwrite` + §1 | SSM command (seconds) or instance replacement |
| GitHub PAT (contents read/write) | SSM `/opencode/github-token` | boot helper → container `/root/.git-credentials` (600) | new PAT + `put-parameter --overwrite` + §2 | helper re-run (seconds) |
| SSH key | `ssh_public_key` var (empty in prod = SSM-only) | — | §3 | instance replacement via pipeline |
| TLS certificate | Caddy `caddy-data` volume on the data disk | Caddy (automatic Let's Encrypt) | automatic | §4 if forced |
| AWS access | GitHub OIDC role, no long-lived keys | pipeline | nothing to rotate | — |

## 1. opencode web password

```bash
# 1. overwrite (values only — history-safe, nothing printed back)
aws ssm put-parameter --region eu-west-1 --name /opencode/server-password \
  --type SecureString --value 'NEW-STRONG-PASSWORD' --overwrite

# 2. target the running instance
IID=$(aws ec2 describe-instances --region eu-west-1 \
  --filters 'Name=tag:Name,Values=opencode-prod-server' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# 3. swap the password line and recreate the container (prints nothing secret)
aws ssm send-command --region eu-west-1 --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["set -euo pipefail", "VALUE=$(aws ssm get-parameter --name /opencode/server-password --with-decryption --query Parameter.Value --output text --region eu-west-1)", "sed -i '\''/^OPENCODE_SERVER_PASSWORD=/d'\'' /opt/opencode/app.env", "printf '\''OPENCODE_SERVER_PASSWORD=%s\\n'\'' \"$VALUE\" >> /opt/opencode/app.env", "chmod 600 /opt/opencode/app.env", "cd /opt/opencode && docker compose up -d"]' \
  --query 'Command.CommandId' --output text
```

Verify: log out of `https://<domain>` and log back in with the new
password (old sessions stay valid until their cookie expires — expected).
A `curl` check keeps the secret out of shell history better than `-u`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/   # want 401, no creds
```

Notes:

- `deploy-app` (app-only pushes) does **not** refetch the password — it only
  re-copies `compose.yaml`/`Caddyfile`. Use the command above or replace
  the instance.
- Pipeline-only alternative (no AWS CLI): overwrite the parameter, then push
  any `user_data.sh` touch — `user_data_replace_on_change` replaces the
  instance and the fresh boot reads the new value. Slower (minutes), zero
  laptop AWS access.
- If the rotation is incident-driven (suspected leak), also purge the
  `-boot` log group stream for the instance — boot logs once carried the
  secret in plaintext (see issue #10):
  `aws logs delete-log-stream --region eu-west-1 --log-group-name
  opencode-prod-boot --log-stream-name "$IID"`.

## 2. GitHub PAT

Order matters: verify the new token works **before** revoking the old one.

```bash
# 1. GitHub → Settings → Developer settings → Personal access tokens →
#    Fine-grained token, contents read/write on your repos only, short expiry.
# 2. overwrite (shown once — copy immediately)
aws ssm put-parameter --region eu-west-1 --name /opencode/github-token \
  --type SecureString --value 'NEW-TOKEN' --overwrite

# 3. re-run the boot helper on the box (same $IID lookup as §1)
aws ssm send-command --region eu-west-1 --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/opencode-git-setup.sh"]'

# 4. only after step 3 reports Success: revoke the old token on GitHub.
```

Verify: the helper exits 0 and asserts `credential.helper = store`.
`deploy-app` re-runs the helper too, so any app push also picks up a
rotated token.

Caveat: until issue #7 (missing `GetParameter` on `/opencode/github-token`
for the instance role) is deployed, step 3 fails with `AccessDenied`. If
so: still overwrite the SSM value and mint the new PAT, but **do not
revoke the old token** until the fix is live and step 3 succeeds.

## 3. SSH key

Prod runs keyless (`ssh_public_key = ""`, SSM-only) — there is nothing to
rotate. If a key is ever issued: generate a new `ed25519` pair offline,
put the public half in `ssh_public_key`, push; the pipeline replaces the
instance (EIP + data disk survive). Destroy the old private key. Return to
empty + SSM-only when the need passes.

## 4. TLS certificate

Caddy renews automatically; there is nothing scheduled. To force renewal
(e.g. key compromise, distrust event):

```bash
aws ssm send-command --region eu-west-1 --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/opencode && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile"]'
```

If the stored cert itself is suspect, stop the stack, clear the
`caddy-data` volume contents (certs re-issue on next start), and start
again. The data disk otherwise never needs touching for rotation.

## 5. Incident rotation (suspected compromise)

1. GitHub: mint a replacement PAT now, but keep the old one until step 4.
2. SSM: overwrite **both** parameters (`server-password`, `github-token`).
3. Box: run the §1 password swap and the §2 helper re-run (two commands).
4. Verify: fresh web login with the new password; helper exit 0.
5. Revoke: old PAT on GitHub; old password is dead the moment step 3
   completes (nothing to revoke — it only ever lived in SSM + `app.env`).
6. Clean: delete the instance's `-boot` log stream (see §1); check the
   `login-probe` / `ssh-probe` alarms for activity during the window.
7. If the box itself is suspect (not just a credential): do not repair it —
   push a commit that replaces the instance; the data volume survives.
   Reads/writes stay pipeline-only per AGENTS.md.

## 6. Cadence

- Web password: every 90 days, or on operator change.
- GitHub PAT: GitHub's own expiry (set ≤ 90 days on fine-grained tokens);
  rotation is steps §2.1–§2.4, no deploy needed.
- SSH: n/a while keyless.
- TLS: automatic; manual only per §4.

## Related

- README "opencode web access" and "Git on the server" (initial seeding).
- ADR-0004 (password), ADR-0010 (git auth), ADR-0006 (alerts to watch).
- Issues #7 (PAT permission), #10 (secret in boot logs), #13 (alert gaps).
