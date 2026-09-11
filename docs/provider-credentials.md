# Provider credentials

Provider API keys are stored as AWS SSM SecureStrings. Terraform contains
only the parameter names; the EC2 instance role is granted
`ssm:GetParameter` only for configured provider parameters.

## Initial setup

Create the parameter outside Terraform:

```bash
aws ssm put-parameter \
  --name /opencode/anthropic-api-key \
  --type SecureString \
  --value 'REDACTED' \
  --overwrite \
  --region eu-west-1
```

Do not put the real value in a shell history if that is a concern; use your
normal secure operator workflow for supplying the value.

The production configuration maps the parameter to `ANTHROPIC_API_KEY`.
The value is fetched on the instance and consumed by `app/opencode.json`
through `{env:ANTHROPIC_API_KEY}`.

## Rotation without replacement

1. Update the SecureString value.
2. Run the refresh command through SSM Run Command:

```bash
aws ssm send-command \
  --instance-ids <INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/opencode-secrets-refresh.sh && cd /opt/opencode && ./switch.sh deploy"]' \
  --region eu-west-1
```

The refresh script keeps shell tracing disabled, rewrites `/opt/opencode/app.env`
atomically with mode `0600`, and includes the configured provider keys. The
blue-green switch then starts the idle backend with the new environment and
only stops the live backend after readiness succeeds.

No Terraform apply or instance replacement is required.

## Adding another provider

1. Create its SSM SecureString.
2. Add the environment-variable-to-parameter mapping in the relevant tfvars.
3. Add that provider's `{env:...}` reference to `app/opencode.json` if it is
   not already configured.
4. Push the change so the normal app bundle deployment distributes the config.

Never commit the provider value itself.
