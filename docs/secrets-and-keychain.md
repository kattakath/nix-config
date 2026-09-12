# Secrets — agenix vault + login Keychain

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Security. `CLAUDE.md` states the hard rules;
this file holds the mechanism, the history, and the two documented footguns.

**The one rule above all:** the `/nix/store` is world-readable, so a plaintext secret never
goes in a `.nix` file — not as a literal, not in a comment, not in an `args` list.

## agenix — an operator-only vault

Encrypted secrets are committed via **agenix**: recipients are declared in
`secrets/secrets.nix` (pure age/SSH, **no `ssh-to-age`**), ciphertext lives in
`./secrets/<name>.age`.

There are **four** committed secrets across **two different models** — one operator-only, three
host-decrypted. Assuming one model covers all of them is the mistake to avoid.

### 1. `cloudflared-token.age` — operator-only

`nixpi`'s Cloudflare tunnel token, encrypted to the **operator's `~/.ssh/id_ed25519` alone**.
This is the **operator-only vault** model: the operator decrypts it on the Mac and plants it on
nixpi's SD card FIRMWARE partition, where the in-tree `modules/features/firmware-secrets/`
capsule's
`services.firmwareProvisioning` copies it into a `/run` file at boot. **nixpi never decrypts it
on-device.**

Why not host-decrypt it? agenix binds a secret to the host's SSH host key, and a fresh SD flash
**rotates that key** — which would break decryption and kill the tunnel, the sole remote path
into `nixpi`. For this secret, host-decryption is a lockout risk.

### 2–4. `gh-app-dontsell-ai-key.age`, `gh-app-fleet-key.age`, `gitlab-runner-token.age` — host-decrypted on `macos`

The three credentials the `macos` CI runner lanes need. Recipients are the operator **plus the
`macos` SSH host key**, so these *are* decrypted at activation into `/run/agenix/<name>` by the
host itself.

| Secret | Consumer | Content |
|---|---|---|
| `gh-app-dontsell-ai-key.age` | `services.macosGithubRunner` (`modules/darwin/github-runner.nix`) — the bare-metal `_github-runner` **daemons** | GitHub App RS256 `.pem` |
| `gh-app-fleet-key.age` | `tart.githubRunners.*` (`nix-tart-vms`, `hosts/macos.nix`) — the login-user Tart **agents** | the *same* App's RS256 `.pem` |
| `gitlab-runner-token.age` | `tart.gitlabRunner` — renders `config.toml` at agent start | the bare `glrt-` token, one line |

**The two `gh-app-*` files hold identical key material, and that is deliberate — not duplication
to clean up.** Both authenticate as the `ismailkattakath-ci` App (appId 4849830), but an agenix
secret has exactly **one** owner, and the consumers run as different users (`_github-runner`
daemons vs. the login user, whose Tart agents need a GUI session for Virtualization.framework).
Rotating the App key therefore means re-encrypting **both**, with `age -R` and a recipient-tag
check — never `agenix -e`. `secrets/secrets.nix` carries the full App history (this App replaced
the retired `kattakath-fleet-ci`, `kattakath-ci` and `dontsell-ai` Apps on 2026-09-06) and the
two-key split against the `kattakath` org secret `CI_BOT_APP_PRIVATE_KEY`.

That is safe here for the reason it wasn't for nixpi: `macos` is a persistent machine whose host
key isn't reflashed, and the keys never leave it. Every GitHub runner registration uses the App
key to mint a fresh ~1 h installation token, so no long-lived bearer credential is stored or
transmitted. (The GitLab `glrt-` token is the exception — it is long-lived by design; rotating it
means re-registering the runner.)

> **The host-decryption path is LIVE.** Earlier revisions of this repo's docs said agenix's
> host-decrypt mechanism was "used by NOTHING" — that was true only between the runner's
> retirement (2026-07-16) and its revival (2026-08-23). Don't repeat it.

When changing recipients, **re-key**: `agenix -r`. The `macos` host key pinned in
`secrets/secrets.nix` was re-verified 2026-08-23 after a host-key rotation had silently
invalidated the previous pin — verify it against the live
`/etc/ssh/ssh_host_ed25519_key.pub` before reusing that value.

Edit any secret with:

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

A darwin-only loader (from the `modules/features/keychain-secrets/` capsule via
`programs.keychainSecrets`, installed to `~/.config/secrets/loader.sh` — the path
`modules/darwin/core.nix` derives `launchd.user.envVariables.BASH_ENV` from, by reference, so
the two halves cannot drift) exports every registered secret into **every**
shell — sourced from zsh's `.zshenv` (via `envExtra`) and bash's profile + `.bashrc` +
`$BASH_ENV`, **NOT** just the login `~/.zprofile`/`~/.bash_profile`. The old login-only wiring
silently starved non-login shells: `zsh -c`, Claude Code's Bash tool, scripts, launchd.

It reads the Keychain at most **once per process tree** (a `__SECRETS_KEYCHAIN_LOADED`
sentinel, exported so descendants inherit and short-circuit; ~470 ms paid once at the tree
root). `SECRETS_DEBUG=1` reports which secrets loaded/failed (names + lengths + exit codes,
**never values**).

### The `secret` command

The store is managed with a single noun-verb command **`secret <verb>`** (the primary interface;
from the `modules/features/keychain-secrets/` capsule). **There is no `secret get`** — it was removed so that
printing a value is always an explicit, named act (`reveal`), never the path of least
resistance:

| Command | Effect |
|---|---|
| `secret set <KEY> [VALUE]` | store (hidden prompt if no VALUE) |
| `secret copy <KEY>` | to the clipboard, concealed + auto-cleared |
| `secret exec <KEY> -- CMD` | into the command's env; never stdout |
| `secret fp <KEY>` | digest + length + mdat, never the value |
| `secret reveal <KEY>` | PRINT it — the only printing verb, use last |
| `secret rm <KEY>` | remove |
| `secret ls [--long]` | list (`list` also accepted) |
| `secret bind <KEY> <ENV>` | export it as `$ENV` in every shell |
| `secret unbind <KEY>` | stop exporting it; reach it via `copy`/`exec`/`fp` |
| `secret adopt <KEY>` | register a Keychain item added outside this CLI |
| `secret load` | reload the whole store into the current shell — the shell-function-only fix for a manually-unset var |

### Cloudflare tokens — scoped, and deliberately NOT ambient

There are three Cloudflare entries, and the split is the point:

| Keychain entry | Scope | Bound to an env var? |
|---|---|---|
| `cf:cloudflare.com:nixpi-tunnel` | Account **Cloudflare Tunnel:Edit** (Personal only) + **DNS / Zone Settings / Dynamic URL Redirects :Edit** on `kattakath.com` + `snoringirl.com` | **no** — `secret exec` only |
| `cf:cloudflare.com:dontsell-dns` | **DNS / Zone Settings / Page Rules :Edit** on `dontsell.ai` only | **no** |
| `cf:cloudflare.com:api` | broad (both accounts, all zones) — kept for ad-hoc work | **no** (was bound, now unbound) |

The broad token used to be `secret bind`-ed to `CLOUDFLARE_API_TOKEN`, so **every** shell — and
therefore every process the operator ever launched, including this repo's own agent tooling —
inherited write access to two accounts and seven zones. That is the opposite of what the
`cf-*` apps' own "export a scoped token" hint asked for. It is now unbound; reach any of them
explicitly:

```bash
secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:nixpi-tunnel -- <the terranix app>
```

Verified by denial, not by reading the dashboard: the scoped token can read/write the two
tunnel zones and the tunnel itself, and is **refused** on aloshy.ai DNS, Workers, Gateway,
devices, listing API tokens, and any Access **write**. It does retain Access *read* (apps,
service tokens, IdPs) — that rides inside Cloudflare's own `Cloudflare Tunnel Write`
permission group and cannot be separated out.

Each is a **shell function** (`set`/`rm`/`bind`/`unbind`/`load` also mutate the current shell —
export/unset/reload) backed by a **PATH binary** *and* a **`nix run .#secret -- …`** app (`load`
is function-only). `set-secret <KEY> [VALUE]` and `remove-secret <KEY>` remain as back-compat
**aliases** for `secret set` / `secret rm`. The mutating verbs forward to `set-secret` so the
Keychain/index logic lives once, and the Keychain index (`__set_secret_index__`) is
authoritative — so **no secret names live in `.nix`**.

### The threat model — ambient by design, and what that costs

Rehomed from `nix-keychain-secrets`' `SECURITY.md` when ADR-002 wave 4 absorbed the flake.
It is not a footnote: it is the reason this store exists *alongside* agenix rather than
instead of it.

**The loader makes every registered secret AMBIENT in every shell of a process tree — on
purpose.** The consequence is exact and worth saying out loud: **any process in that tree —
a compromised dependency, a `postinstall` script, an AI coding agent — can read every
exported value with `env`.** That is the right trade for *laptop/dev API keys*, where the
alternative is the token sitting in a dotfile in git. It is the **wrong** trade for
high-value, server, or shared-machine secrets; those belong in the agenix vault above (or
sops-nix / 1Password), which decrypt per-consumer and never reach a shell environment.

Two properties bound the blast radius, and neither softens the sentence above:

- Values rest in the **login Keychain** (encrypted at rest) and in process memory. Neither
  the values nor the key NAMES reach `/nix/store` or git — the index
  (`__set_secret_index__`) is itself a Keychain item.
- A secret can be stored **without** an env binding (`secret bind`/`unbind`, or the
  `=SERVICE` index form). Unbound secrets are never exported and are reached on demand with
  `copy`/`exec`/`fp`/`reveal` — which is exactly what the three Cloudflare tokens above do.

The upstream repo's "report a vulnerability" section did **not** come along: the flake is
archived, and this fleet's disclosure path is `SECURITY.md` at the repo root.

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

Same rule: `VAST_API_KEY` plus the read-only tokens live in the login Keychain and are
pushed to Vast **account-level** env vars via `nix run .#vast-account-vars-set` (injected
into every instance, never baked into the template); provisioner stacks are private
GitLab repos. See [`vastai-template-provisioning.md`](vastai-template-provisioning.md).

**The `VAST_<NAME>` prefix is gone** (pinned input `vast-provision`, 2026-09-06). It
existed to mark a token as safe to sync and paid for that marker by duplicating every
credential; the duplicates then rotted — all four were missing from the Keychain, so the
sync pushed nothing and said so only as four `SKIP` lines.

**The Vast variable names are fixed, not chosen.** The container reads them:
`GITLAB_TOKEN`/`GH_TOKEN` for clone auth (`vast-bootstrap.sh`, `provision-lib.sh`
`fetch_gitref`) and `CIVITAI_TOKEN`/`HF_TOKEN` for downloads (`fetch_civitai`). So the
*source* is aliased where the operator's canonical entry is spelled differently:

| Vast variable (fixed) | Keychain entry read | Present? |
|---|---|---|
| `GITLAB_TOKEN` | `GITLAB_TOKEN` — operator PAT (`api`, `create_runner`, `manage_runner`) | ✅ |
| `HF_TOKEN` | `HF_TOKEN` | ✅ |
| `CIVITAI_TOKEN` | `CIVITAI_API_TOKEN` | ✅ |
| `GH_TOKEN` | `GITHUB_PERSONAL_ACCESS_TOKEN` | ✅ |
| — | `VAST_API_KEY` (Vast's own key), `DOCKERHUB_TOKEN` (rent-time only) | **never synced** |

⚠️ **Nothing in a name says "this leaves the machine" any more.** The argument list to
`vast-account-vars-set` is the only guard, and anything it pushes is readable by the
third-party GPU host operator. The default set is all four rows above — which means
`GITHUB_PERSONAL_ACCESS_TOKEN`, a full-scope PAT, ships to every instance on a bare
`vast-account-vars-set`. That is an accepted trade (2026-09-06, operator shown the
scope); **name tokens explicitly if you want less**, e.g.
`nix run .#vast-account-vars-set -- GITLAB_TOKEN HF_TOKEN`.

## Cachix write token

`CACHIX_AUTH_TOKEN` lives in exactly two places — a **GitHub Actions secret** and (since
2026-08-21) the operator's **login Keychain** — never in Nix or git; read stays public and
tokenless on every consumer. Details in [`repo-map.md`](repo-map.md) § Binary cache.

## Never display a secret value

Reading a secret to *use* it (env var, `passwordCommand`) is fine; **displaying** it is not —
no `echo`/`cat`/log/commit/PR body/tool-output quote. Refer to a secret by its name/handle. When
unsure whether a string is sensitive, treat it as sensitive.
