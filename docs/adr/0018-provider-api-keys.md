# ADR-0018: Provider API Keys from SSM SecureStrings

## Status

Accepted

## Date

2026-09-11

## Context

OpenCode needs provider credentials such as `ANTHROPIC_API_KEY` and
`OPENAI_API_KEY` to make model calls. The repository must remain safe to
share, and provider keys must not enter Terraform state, Git history, CI
logs, Docker images, or the managed `opencode.json`.

The global OpenCode configuration is versioned in `app/opencode.json`. It
can therefore contain references such as `{env:ANTHROPIC_API_KEY}`, but not
the values themselves.

## Decision

Provider credentials are operator-created AWS SSM SecureStrings. Terraform
accepts a map from environment-variable name to SSM parameter name:

```hcl
provider_api_key_parameters = {
  ANTHROPIC_API_KEY = "/opencode/anthropic-api-key"
  OPENAI_API_KEY    = "/opencode/openai-api-key"
}
```

Only parameter names enter Terraform configuration/state. The EC2 instance
role receives `ssm:GetParameter` on exactly the non-empty configured
parameter ARNs. The boot script fetches those values with `set -x` disabled
and writes them to the root-only `/opt/opencode/app.env` file.

`app/opencode.json` references the runtime variables with OpenCode's
`{env:VAR}` substitution. The config is bundled with the other application
files and mounted read-only into both blue and green backend containers.

An empty parameter name means that provider is not configured. Local and
boot tests use dummy values only.

## Rotation

Rotation does not require Terraform or instance replacement. Update the
SSM SecureString and use the existing app deployment/restart path so a fresh
`app.env` is fetched before the backend color is switched.

## Security constraints

- Never put provider key values in tfvars, Terraform variables, or outputs.
- Never echo provider values while shell tracing is enabled.
- Keep `/opt/opencode/app.env` mode `0600`.
- Grant the instance only `ssm:GetParameter` for configured provider
  parameters.
- Keep provider references, not provider values, in `app/opencode.json`.
- Local tests must use dummy credentials and must not call real providers.

## Consequences

### Positive

- Secrets stay outside Git, Terraform state, and CI.
- Rotation is independent of infrastructure deployment.
- Adding another provider requires only an SSM parameter mapping plus its
  OpenCode config entry.
- The same runtime contract works for blue-green switches.

### Negative

- Each provider requires an operator-created SSM parameter.
- A missing configured parameter fails boot rather than silently starting
  an unusable backend.
- The managed config must know the provider's OpenCode environment-variable
  name.

## Related decisions

- ADR-0003: supply-chain and secret hygiene.
- ADR-0004: SSM SecureString for the machine-only OpenCode password.
- ADR-0011: application bundle deployment.
- ADR-0015: zero-downtime blue-green deployment.
