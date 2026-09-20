# cloud-cli

**The tool and the shape, never the content.** `local.cloudCli.aws.enable` installs the AWS
CLI (upstream `programs.awscli`) and `aws-sso-util`, and writes `~/.aws/config.example` with
`<<PLACEHOLDERS>>`. It never writes `~/.aws/config` — that file is yours.

> **Provenance.** Born in-tree, 2026-09-20 (ADR-004 phase 3). It replaced the operator's
> committed `programs.awscli.settings` block in `hosts/macos.nix`, which carried two real
> account ids and an SSO start-URL id into a public repo (ADR-004 §7, inventory #1). The first
> activation after that block left Nix keeps the operator's profiles: `adoptAwsConfig` in
> `modules/shared/claude-bedrock-gate.nix` turns the leftover store symlink into a real
> `0600` file rather than letting home-manager's orphan cleanup delete it.

## Use

```nix
local.cloudCli.aws.enable = true;      # in a user's home-manager block
# local.cloudCli.aws.ssoTooling = false;   # skip aws-sso-util
```

Then, once, on the machine:

```sh
cp ~/.aws/config.example ~/.aws/config && "$EDITOR" ~/.aws/config   # or: aws configure sso
aws sso login --sso-session <name>
```

`~/.aws/config` is read at runtime by the `aws` CLI and by `nix-bedrock-gate`
(`modules/shared/claude-bedrock-gate.nix`); select Claude Code's Bedrock profile with
`secret set AWS_PROFILE <profile>`.

## Why the real file is not declared here

| Argument | Consequence |
|---|---|
| Account ids, start-URL ids, regions are **reconnaissance**, not credentials | they stay on the machine; the public repo ships only the shape |
| Every user's shape differs (SSO admin / IAM-less junior / preview-only senior) | one committed file cannot be right for anyone but its author |
| Sessions are **SSO/OIDC-minted** (`aws sso login`) | almost nothing needs long-lived storage; the token cache never was in Nix |

This is ADR-003's "content out, governance in" (§10.3) made into a capsule, and the AWS tier of
`docs/identity-and-offboarding.md`: the privileged exception, granted per person, held locally.

## Checks

`checks.<system>.cloud-cli-module` (enabled → tools present, exactly one `~/.aws/*` target and it
is the example) and `cloud-cli-inert` (imported + disabled → `home.packages` identical to a
config that never imported it; no `.aws/*` file). Both systems.
