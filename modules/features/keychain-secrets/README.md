# keychain-secrets

**Your API keys in every shell — from the macOS login Keychain, not a dotfile.**

A noun-verb CLI (`secret set/reveal/rm/ls/…`) backed by the macOS login Keychain, plus a
home-manager loader that exports your registered secrets into **every** shell — login,
non-login, interactive or not, **including the bash an AI coding agent spawns for its
tools**. Nothing secret (not even the key *names*) is ever written to the Nix store or to
git. No age/GPG key, no `.sops.yaml`, no subscription.

> **Provenance.** This was `github.com/kattakath/nix-keychain-secrets`, a standalone MIT
> flake, until ADR-002 ([`docs/monoflake-capsule-adr.md`](../../../docs/monoflake-capsule-adr.md))
> collapsed the seven satellites into this repo as *capsules*. The code arrived by plain
> copy; the git history stays in the archived origin repo. MIT © Ismail Kattakath.

## The problem it solves

The usual "secrets in my shell" tricks break for **non-login shells**: a plain
`export FOO=…` in `.zshrc`/`.bash_profile` never reaches `zsh -c` from a Makefile, a VS Code
task, a launchd job, or **an AI agent's Bash tool** — so those processes silently get *zero*
secrets. This wires all four shell entry points (`.zshenv`, `.bash_profile`, `.bashrc`, and
non-interactive bash's only hook, `$BASH_ENV`) to a single loader that reads the Keychain
**once per process tree** (a `__SECRETS_KEYCHAIN_LOADED` sentinel; ~470 ms paid once at the
root) and exports each value to every descendant.

## How it is wired here

`modules/shared/home.nix` imports this capsule's `module.nix` and sets
`programs.keychainSecrets.enable = true`; it is darwin-gated internally, so it is a clean
no-op on `nixpi`/`nixvm`. The module reaches the consumer through
`modules/parts/compose.nix` as the `keychainSecretsModule` specialArg — **not** through
`flake.modules`, for a measured reason recorded in `modules/parts/capsules.nix` § The RAW
module seam.

Two things outside this directory depend on it and must not drift:

- **`modules/darwin/core.nix`** derives `launchd.user.envVariables.BASH_ENV` from
  `programs.keychainSecrets.loaderRelPath` **by reference**. That is what closes the
  `$BASH_ENV` gap for a bash spawned by a GUI app or a launchd job, which descends from no
  shell at all. `checks/module-evaluates.nix` pins the option's default as a literal so a
  silent rename cannot move one half without the other.
- **`modules/shared/claude-bedrock-gate.nix`** runs at `lib.mkOrder 1600` on the same three
  shell-init options this module writes at `lib.mkAfter` (= 1500), because it *reads* a
  variable this loader exports. `checks.<system>.bedrock-gate-after-loader`
  (`modules/parts/checks.nix`) asserts that order against the real `macos` config.

The three CLIs are also flake outputs on darwin — `nix run .#secret`, `.#set-secret`,
`.#remove-secret` — registered by this capsule's `flake-module.nix`.

## Usage

```sh
secret set OPENAI_API_KEY          # hidden prompt (or: secret set KEY value)
secret reveal OPENAI_API_KEY       # PRINT it (last resort; there is no `get`)
secret copy glab:gitlab.com:token  # to the clipboard, concealed + auto-cleared
secret exec GH=gh:github.com:pat -- gh pr list   # value only in the child's env
secret fp  GITLAB_TOKEN            # digest + length + mdat, never the value
secret ls                          # list registered names (never values)
secret rm  OPENAI_API_KEY          # delete + unregister
secret bind/unbind <KEY> [ENV]     # control whether it becomes ambient at all
secret adopt SOME_KEY              # register an item added outside the CLI
secret load                        # re-load into the CURRENT shell

# pb-conceal is the pasteboard half, usable on its own with any value on stdin:
printf %s "$v" | pb-conceal --clear 45
```

`set-secret` / `remove-secret` remain as back-compat aliases. `set`/`rm`/`adopt`/`bind`/
`unbind`/`load` also update your *current* shell (a bare binary can't touch its parent's
env, so those run as a shell function from the loader).

**There is no `secret get`.** It was removed so that printing a value is always an explicit,
named act (`reveal`) rather than the path of least resistance — and with it the bare
`secret <KEY>` shorthand, which made a *missing verb* silently become a disclosure.

## How it works

- **Store:** macOS login Keychain (`security` generic passwords), account = `id -un`.
- **Index:** one Keychain item (`__set_secret_index__`) holds the space-separated list of
  managed keys. The grammar — `ENV=SERVICE`, `=SERVICE` (stored but never exported), or a
  bare legacy `SERVICE` — is defined canonically in `packages/set-secret.nix`; `module.nix`'s
  loader and `packages/secret.nix` both parse it, and **all three must agree**. The index is
  **single-writer**: only `secret set`/`rm` maintain it, so an item added out-of-band
  (Keychain Access GUI, raw `security add-generic-password`) is found by a direct read but is
  invisible to `ls` and to the loader until `secret adopt <KEY>` — which registers it and, as
  a bonus, rewrites the item so the CLI is on its ACL (no more per-read auth prompts).
- **Loader:** `~/.config/secrets/loader.sh`, sourced by every shell; loads once per tree via
  an exported sentinel; `SECRETS_DEBUG=1` reports names/lengths/exit codes (never values).
- **Nothing on disk/git:** only the loader *script* lives outside the Keychain; values and
  key names never leave it except into process memory.

## ⚠️ Security model — read this

This deliberately makes your secrets **ambient in every shell**. That means **any process in
the tree — including a compromised dependency or the AI agent itself — can read them via
`env`.** That is the correct trade-off for *laptop / dev API keys* whose whole point is to be
present for your tools. It is **not** a model for high-value secrets, servers, or shared
machines — this fleet runs `agenix` alongside it for those. The full statement, and the two
properties that bound the blast radius, live with the rest of the fleet's secret policy in
[`docs/secrets-and-keychain.md`](../../../docs/secrets-and-keychain.md) § The threat model.

- Values rest only in the Keychain (encrypted at rest) and in process memory.
- First `security` read may trigger a Keychain ACL prompt — allow it once.
- Onboarding a new Mac still needs `secret set …` (or a Keychain restore); a rebuild
  provisions the *loader*, not the secret *values*.

## Tests

`tests/grammar.sh` is a **functional** test of the index grammar against a throwaway
keychain (`SET_SECRET_KEYCHAIN`), and it deliberately is **not** a `nix flake check`
derivation — the build sandbox has no login session and no Keychain, so every assertion
would fail there for reasons unrelated to the code:

```sh
nix develop -c modules/features/keychain-secrets/tests/grammar.sh
```

The two gated checks are `checks.aarch64-darwin.keychain-secrets-module` (the loader's
`$BASH_ENV` wiring and sentinel, on a throwaway home-manager config) and
`keychain-secrets-clis` (builds all four CLIs, which is what runs shellcheck over them).

## When to use something else

| You want… | Use |
|---|---|
| Git-encrypted, multi-machine, or server secrets | [sops-nix](https://github.com/Mic92/sops-nix) / [agenix](https://github.com/ryantm/agenix) |
| Just-in-time, short-lived, team-shared secrets | [1Password CLI](https://developer.1password.com/docs/cli/) (`op run`) |
| Secrets only inside `nix develop` | [agenix-shell](https://github.com/aciceri/agenix-shell) |
| Per-project (not global) env | [direnv](https://direnv.net/) |
| **Global laptop API keys in *every* shell, incl. agent bash, no crypto ceremony** | **this** |

## Prior art declined — why this isn't just `envchain`

`pkgs.envchain` is in the pinned nixpkgs and is the obvious off-the-shelf answer. It does not
fit, for reasons read off its own source rather than recalled — the full citation is the
header comment of `module.nix`. In short: envchain's only exec form is
`envchain NAMESPACE CMD [ARG…]`, i.e. **wrapper-scoped**, and the requirement here is *every*
shell including the non-interactive bash an agent spawns per tool call, which nobody gets to
wrap.
