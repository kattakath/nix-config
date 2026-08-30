# Secrets — agenix vault + login Keychain

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Security. `CLAUDE.md` states the hard rules;
this file holds the mechanism, the history, and the two documented footguns.

**The one rule above all:** the `/nix/store` is world-readable, so a plaintext secret never
goes in a `.nix` file — not as a literal, not in a comment, not in an `args` list.

## agenix — an operator-only vault

Encrypted secrets are committed via **agenix**: recipients are declared in
`secrets/secrets.nix` (pure age/SSH, **no `ssh-to-age`**), ciphertext lives in
`./secrets/<name>.age`.

There are **two** committed secrets, and they use **two different models**. Assuming one model
covers both is the mistake to avoid.

### 1. `cloudflared-token.age` — operator-only

`nixpi`'s Cloudflare tunnel token, encrypted to the **operator's `~/.ssh/id_ed25519` alone**.
This is the **operator-only vault** model: the operator decrypts it on the Mac and plants it on
nixpi's SD card FIRMWARE partition, where the `nix-firmware-secrets` flake's
`services.firmwareProvisioning` copies it into a `/run` file at boot. **nixpi never decrypts it
on-device.**

Why not host-decrypt it? agenix binds a secret to the host's SSH host key, and a fresh SD flash
**rotates that key** — which would break decryption and kill the tunnel, the sole remote path
into `nixpi`. For this secret, host-decryption is a lockout risk.

### 2. `gh-app-dontsell-ai-key.age` — host-decrypted on `macos`

The `macos` self-hosted runner's GitHub **App** RS256 private key
(`modules/darwin/github-runner.nix`, `services.macosGithubRunner`). Recipients are the operator
**plus the `macos` SSH host key**, so this one *is* decrypted at activation into
`/run/agenix/<name>` by the host itself.

That is safe here for the reason it wasn't for nixpi: `macos` is a persistent machine whose host
key isn't reflashed, and the key never leaves it. Every runner registration uses it to mint a
fresh ~1 h installation token, so no long-lived bearer credential is stored or transmitted.

> **The host-decryption path is LIVE.** Earlier revisions of this repo's docs said agenix's
> host-decrypt mechanism was "used by NOTHING" — that was true only between the runner's
> retirement (2026-07-16) and its revival (2026-08-23). Don't repeat it.

When changing recipients, **re-key**: `agenix -r`. The `macos` host key pinned in
`secrets/secrets.nix` was re-verified 2026-08-23 after a host-key rotation had silently
invalidated the previous pin — verify it against the live
`/etc/ssh/ssh_host_ed25519_key.pub` before reusing that value.

Edit either secret with:

```bash
agenix -e secrets/<name>.age    # uses ~/.ssh/id_ed25519 directly — no SOPS_AGE_KEY_FILE ceremony
```

History: agenix was adopted **2026-07-08**, replacing **sops-nix** — a deliberate preference for
the simpler age/SSH model. The older `/etc/secrets` operator-placed model was retired in #109.
The `cloudflared-connector` module still *defaults* `tokenFile` to
`/etc/secrets/cloudflared-token` for hosts that don't opt into agenix, but `nixpi` overrides it
to a `/run` file planted from the FIRMWARE partition.

## Personal tokens — the login Keychain

Personal tokens live in the macOS **login Keychain** (the single source of truth) or come from
one-time CLI logins (`gh`/`hf`/`docker`/`claude`). Never literals in `.nix`.

A darwin-only loader (from the `nix-keychain-secrets` flake via `programs.keychainSecrets`,
installed to `~/.config/secrets/loader.sh`) exports every registered secret into **every**
shell — sourced from zsh's `.zshenv` (via `envExtra`) and bash's profile + `.bashrc` +
`$BASH_ENV`, **NOT** just the login `~/.zprofile`/`~/.bash_profile`. The old login-only wiring
silently starved non-login shells: `zsh -c`, Claude Code's Bash tool, scripts, launchd.

It reads the Keychain at most **once per process tree** (a `__SECRETS_KEYCHAIN_LOADED`
sentinel, exported so descendants inherit and short-circuit; ~470 ms paid once at the tree
root). `SECRETS_DEBUG=1` reports which secrets loaded/failed (names + lengths + exit codes,
**never values**).

### The `secret` command

The store is managed with a single noun-verb command **`secret <set|get|rm|ls|load>`** (the
primary interface; from the `nix-keychain-secrets` flake):

| Command | Effect |
|---|---|
| `secret set <KEY> [VALUE]` | store (hidden prompt if no VALUE) |
| `secret get <KEY>` | lazy read |
| `secret rm <KEY>` | remove |
| `secret ls` | list (`list` also accepted) |
| `secret load` | reload the whole store into the current shell — the shell-function-only fix for a manually-unset var |

Each is a **shell function** (`set`/`rm`/`load` also mutate the current shell — export/unset/
reload) backed by a **PATH binary** *and* a **`nix run .#secret -- …`** app (`load` is
function-only). `set-secret <KEY> [VALUE]` and `remove-secret <KEY>` remain as back-compat
**aliases** for `secret set` / `secret rm`. The mutating verbs forward to `set-secret` so the
Keychain/index logic lives once, and the Keychain index (`__set_secret_index__`) is
authoritative — so **no secret names live in `.nix`**.

### Two documented behaviours (not bugs)

1. **The `$BASH_ENV` gap.** Non-interactive non-login **bash** is reached only via `$BASH_ENV`,
   so a bash started with `$BASH_ENV` scrubbed from its environment is the one residual gap.
   zsh has no such gap — `.zshenv` is filesystem-based.
2. **The sentinel is per-*set*, not per-secret.** A child that drops one var
   (`unset FOO` / `env -u FOO`) is **NOT** auto-restored, since the inherited sentinel
   short-circuits the loader. Reload with
   `unset __SECRETS_KEYCHAIN_LOADED && source ~/.config/secrets/loader.sh`, or just open a
   fresh shell.

## Vast.ai tokens

Same rule: `VAST_API_KEY` plus the read-only
`VAST_GITLAB_TOKEN`/`VAST_HF_TOKEN`/`VAST_CIVITAI_TOKEN`/`VAST_GH_TOKEN` live in the login
Keychain and are pushed to Vast **account-level** env vars via
`nix run .#vast-account-vars-set` (injected into every instance, never baked into the
template); provisioner stacks are private GitLab repos. See
[`vastai-template-provisioning.md`](vastai-template-provisioning.md).

## Cachix write token

`CACHIX_AUTH_TOKEN` lives in exactly two places — a **GitHub Actions secret** and (since
2026-08-21) the operator's **login Keychain** — never in Nix or git; read stays public and
tokenless on every consumer. Details in [`repo-map.md`](repo-map.md) § Binary cache.

## Never display a secret value

Reading a secret to *use* it (env var, `passwordCommand`) is fine; **displaying** it is not —
no `echo`/`cat`/log/commit/PR body/tool-output quote. Refer to a secret by its name/handle. When
unsure whether a string is sensitive, treat it as sensitive.
