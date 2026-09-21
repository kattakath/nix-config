# New Mac runbook

Standing up a Mac — brand new, or freshly wiped — from nothing.

## The one command

```bash
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash
```

`| bash -s -- --check` reports what it would do and changes nothing.

It does four things, and only the first three are irreducible:

1. clears a leftover "Nix Store" APFS volume + stale `/etc/synthetic.conf`/`/etc/fstab`
   entries from a previous install (a macOS reset leaves these behind and the
   installer then dies mounting `/nix`)
2. installs Determinate Nix (the curl CLI installer, never the `.pkg`)
3. moves the installer's `/etc/nix/nix.custom.conf` aside, since nix-darwin owns that path
4. clones this repo to `~/Developer/github.com/kattakath/nix-config` and activates
   `#macos` under `sudo -H`

The clone path is **load-bearing**: `modules/parts/hosts.nix` plants
`/etc/nix-darwin/flake.nix` pointing there, which is what lets every later rebuild
be a bare `activate` from any directory. Change one, change the other.

That first activation is the only time the long form is needed. Afterwards
`activate` is on `PATH` and `/etc/nix-darwin` exists, so rebuilding is:

```bash
activate                 # from anywhere; self-elevates, prompts Touch ID
```

## It does not manage your SSH keys — on purpose

Key custody is a personal choice, and this fleet's posture is that **a lost
machine's keypair stays lost**. There is no recovery kit, no key transport, no
passphrase-encrypted blob in iCloud. (There used to be — `key-backup`/`key-recover`,
removed 2026-09-15 as early-days scaffolding.)

Nothing is unrecoverable, because nothing here is a *key to enter*. Every agenix
secret is re-issuable by the vendor that minted it:

| Secret | Re-issue from |
|---|---|
| `cloudflared-token.age` | Cloudflare — the `cf-tunnel-apply` app prints a fresh connector token |
| `gh-app-dontsell-ai-key.age` | GitHub App settings — generate a new private key |
| `gh-app-fleet-key.age` | the same App (identical material on purpose — rotate both together) |
| `gitlab-runner-token.age` | GitLab — re-register the runner |

## After activating, on a Mac whose old keypair is gone

1. **Generate a keypair.** `ssh-keygen -t ed25519`.
2. **Re-upload the pubkey** wherever passwordless auth is wanted — GitHub, GitLab,
   and any host you SSH to.
3. **Repoint agenix** at the new key: put the new pubkey in
   `secrets/operator-key.nix`, then re-encrypt each secret with its fresh vendor
   value (`agenix -e secrets/<name>.age`). The old ciphertext is encrypted to the
   lost key and to the lost host key; it is not coming back, and does not need to.
4. **Commit and push** `secrets/operator-key.nix` plus the re-encrypted `.age` files.

Until step 3, `/run/agenix/*` stays empty. That does **not** block activation —
agenix decrypts from its own `org.nixos.activate-agenix` launchd daemon, not
inline in `activate` — but the self-hosted runners will crash-loop under
`KeepAlive` until their secrets exist. Expected, and harmless if you are not
running CI that hour.

### `nixpi` is the one real lock-out risk

`modules/nixos/core.nix` gives the Pi `authorizedKeys = [ operatorSshKey ]` with
`PasswordAuthentication = false`. Lose the operator key and you cannot SSH, which
means you cannot deploy a replacement key — the fix is a **physical SD reflash**
([`nixpi-sd-flashing-runbook.md`](nixpi-sd-flashing-runbook.md), ~40 min).

AWS hands you a new keypair from its console; a Pi on a shelf does not. The
durable answer is to stop treating a static key as the credential at all —
Cloudflare Access for Infrastructure issues short-lived, IdP-gated SSH
certificates, so the Pi trusts a CA rather than a key you have to keep.

## Conventions worth not re-litigating

- **Determinate Nix via the curl CLI installer, never the `.pkg`.**
- **Activation goes through this flake's own `#macos` app**, so it uses the
  nix-darwin pinned in `flake.lock`. An earlier bootstrap called the nix-darwin
  flake unpinned and broke mid-run when upstream removed `darwin-rebuild`'s sudo
  self-elevation.
- **`osascript` is for notifications and confirmations only — never for
  authentication or secrets.** Privilege escalation goes through `sudo` (Touch ID,
  via `security.pam.services.sudo_local.touchIdAuth`). Every dialog degrades to a
  terminal prompt when there is no GUI session, so nothing wedges a headless run.

## Manual steps Nix can't do

`darwin-rebuild switch` restores everything declarative, but a few browser/GUI
one-time steps are inherently manual — do these after activating a fresh Mac:

- **App logins / personal tokens** — `gh` / `hf` / `docker` / `claude` one-time CLI
  logins and any Keychain-stored personal tokens are re-established by hand (Nix
  manages only the *service* secrets via agenix — see the "Secrets — agenix"
  convention in `CLAUDE.md`, not personal logins).
- **Claude Code's MANAGED settings need a `/status` check — `nix flake check` cannot verify
  this.** `local.claudeManagedSettings` (on `macos`) writes a root-owned
  `/Library/Application Support/ClaudeCode/managed-settings.json` at activation. Open Claude
  Code and run **`/status`**: `Enterprise managed settings (file)` must appear under **Setting
  sources**. If that line is absent the file is misplaced or unparsed and the whole tier
  enforces nothing, however green the flake check was — claude-code 2.1.260's own words for
  that case are "Managed settings document could not be parsed as a JSON object; none of its
  settings are in effect." `pkgs.formats.json` already guarantees the bytes PARSE, so what
  `/status` actually confirms is PLACEMENT. The residual gap nothing in this repo closes is a
  key this build does not recognise: accepted, listed, enforcing nothing.
  If the fresh Mac already carries an MDM or hand-placed file at that path, activation does not
  clobber it — it ABORTS with exit 2 and names both paths; rename the foreign file by appending
  `.before-nix-darwin`, or set `local.claudeManagedSettings.enable = false`.
- **Tart VM disks are NOT restored by a rebuild.** They live under `~/.tart/`; neither this repo nor the key kit restores them (the `macvm` guest itself was removed 2026-09-05 — re-add path: [`macvm-readd-runbook.md`](macvm-readd-runbook.md)).
- **Google Takeout video shows the generic MP4 icon — re-encode with
  `fix-google-video`.** Google's Storage Saver tier transcodes to
  **VP9-in-MP4** server-side, and macOS ships no VP9 decoder, so QuickLook can
  never decode a frame. Duration and dimensions still display (container header,
  not a decoded frame), which makes it read as a thumbnail-cache bug rather than
  a codec gap — and only *some* files are affected, since anything Google left
  alone comes back as H.264 and thumbnails fine. Find them with
  `mdfind -onlyin ~/Pictures 'kMDItemCodecs == "vp09"'`, then run
  `media-transcode <file>...` (on PATH from the `modules/features/media-cli/` capsule via
  `local.mediaCli.enable`; it left this repo in the 2026-09-05 extraction, was renamed
  there, and came back in-tree with ADR-002 wave 5)
  — it detects the codec, re-encodes on the hardware encoder, preserves
  the dates, and skips anything already editor-safe. The container is not the
  problem, so a remux cannot help; only a re-encode does.

  A QuickLook plug-in is **not** a way around this. `quicklook-video`
  (Marginal/QLVideo) was tried and removed: what it ships are macOS **Media
  Extensions**, and its format reader's `MTFileNameExtensionArray` claims
  mkv/webm/avi/wmv/flv/rm but **not `mp4`** — Apple parses MP4 natively, so the
  extension is bypassed before the codec question is asked. Its decoder also
  advertises VP9 as `VP9 `, while the tag MP4 actually carries
  (`kCMVideoCodecType_VP9`) is `vp09`. Verified on macOS 26.6.2 with QLVideo
  3.11, extensions enabled and rebooted: no thumbnail, and no `qlvideo` process
  ever spawned — a lossless remux to `.mkv` did not help either.

- **Determinate's native Linux builder needs a per-machine login, not just an
  account entitlement.** A fresh Mac reinstall means a fresh `determinate-nixd`
  daemon that has never authenticated to FlakeHub — even though the
  `native-linux-builder` feature is already granted on the account (one-time,
  via https://dtr.mn/features / Determinate support), `determinate-nixd status`
  will show `Authentication: logged-out` and `determinate-nixd version` will
  list only `lazy-trees`, not `native-linux-builder`. Symptom if missed: any
  `aarch64-linux` (or `x86_64-linux`) build/`nix run` fails with `error: Cannot
  build '...': Reason: platform mismatch — Required system: 'aarch64-linux',
  Current system: 'aarch64-darwin'`, which reads like a config bug but isn't
  one — `nix show-config`'s `external-builders` is simply empty until login
  happens. Fix, after activating the fresh Mac:
  1. Generate a token at <https://flakehub.com/user/settings?editview=tokens>.
  2. Store it durably: `secret set FLAKEHUB_TOKEN` (hidden prompt), so this
     never has to be redone from scratch on the NEXT reinstall either.
  3. `secret exec FLAKEHUB_TOKEN -- sh -c 'determinate-nixd auth login token --token-file <(printf %s "$FLAKEHUB_TOKEN")'`
     — or write it to a temp file first if your shell doesn't support
     `<(...)` process substitution, then `rm` the file immediately after.
  4. Confirm: `determinate-nixd status` shows `Logged in: true`, and
     `determinate-nixd version` lists `native-linux-builder`.
  A stale/never-updated `determinate-nixd` binary can also hide this — the
  version this was verified against required `sudo determinate-nixd upgrade`
  first when the daemon was a patch behind.

- **A changed `/etc/nix/nix.custom.conf` is INERT until the nix daemon
  restarts — activation does not bounce it.** The file itself is fully
  declarative (`determinateNix.customSettings` regenerates it every
  activation), so nothing here is ever hand-edited. But the **daemon reads that
  config at startup**, and Determinate owns the daemon (`nix.enable = false`),
  so nix-darwin never restarts it: grepped the pinned determinate module, its
  only `system.activationScripts` hook is a `mkdir` for the linux-builder
  working directory.
  The symptom is genuinely confusing, because the two halves disagree:
  `nix config show trusted-users` reports the NEW value (the client just reads
  the merged file) while the daemon keeps enforcing the old one. Measured
  2026-09-15 with `trusted-users`: the file said `extra-trusted-users = ismail`
  and `nix config show` agreed, yet every override came back
  `ignoring the client-specified setting '…', because it is a restricted
  setting and you are not a trusted user` — across two activations, because the
  daemon had been up since before either of them.
  Fix (needs sudo), using **Determinate's** label, not `org.nixos.nix-daemon`:

  ```bash
  sudo launchctl kickstart -k system/systems.determinate.nix-daemon
  ```

  A reboot does the same. **On a from-scratch Mac the same ordering applies** —
  the installer starts the daemon, then `nix run .#macos` writes the file, so
  the setting is inert until something restarts it — but it self-heals on the
  first reboot, which is why it only really bites when changing a daemon-level
  setting on a machine that is already up.
  Scope: this is not specific to `trusted-users`. Everything in that file
  (`extra-substituters`, `extra-trusted-public-keys`, `sandbox`,
  `auto-optimise-store`) is daemon-read-at-startup, and so is
  `/etc/determinate/config.json` (`determinateNixd.garbageCollector.strategy`);
  the older entries simply predate any running daemon, so nobody noticed until
  one changed. One kickstart covers both files — the same process reads them.

  **Verify BEHAVIOURALLY, never with `nix config show`.** Per the paragraph
  above, that command reports the client's parse of the file, so it says "true"
  the moment activation finishes and can never distinguish a daemon that picked
  the setting up from one that did not. Each setting needs its own probe. For
  `trusted-users`, attempt a restricted override (e.g.
  `--narinfo-cache-negative-ttl 0`) and check it is not refused. For
  `auto-optimise-store`, add two differently-NAMED files with IDENTICAL bytes
  and compare inodes — different store paths, one inode means the daemon
  deduplicated on the way in:

  ```bash
  d=$(mktemp -d); echo probe-$$ > "$d/alpha.txt"; cp "$d/alpha.txt" "$d/beta.txt"
  a=$(nix store add-path "$d/alpha.txt"); b=$(nix store add-path "$d/beta.txt")
  [ "$(stat -c %i "$a")" = "$(stat -c %i "$b")" ] && echo deduplicated || echo NOT
  ```

  (`stat -c` is GNU syntax on purpose: this fleet puts GNU coreutils ahead of
  the BSD tools on `PATH`, so a bare `stat` is GNU's — reach for
  `/usr/bin/stat -f` only when you specifically want the BSD one. The two probe
  paths are garbage and the background collector now reaps them on its own.)

## Hand-placed files that never come back from a rebuild (ADR-004, 2026-09-20)

These are the operator's CONTENT; the flake ships only their shape. A fresh Mac needs them
written by hand (or restored from your own backup) — a missing one degrades silently:

| File | Why it is not in Nix | Shape |
|---|---|---|
| `~/.aws/config` | account ids / start-URL ids are reconnaissance; every user's differs | copy `~/.aws/config.example` (written by `local.cloudCli.aws`) or `aws configure sso` |
| `~/.config/git/silvercreek.inc`, `~/.config/git/izzykatt.inc` | personal mailboxes and a persona | `[user]` + `email` (+ `name` for the persona) — the `includes` in `modules/shared/home.nix` name them |
| `~/.config/git/allowed_signers` | lists every mailbox you author as | `<mailbox> namespaces="git" <your ssh public key>`, one line per address; signing works without it, only VERIFYING needs it |
| `~/.config/git/infin8.inc` | the work identity (always was hand-placed) | `[user]` + `email` |
| the login Keychain's secrets | never in Nix | `secret set …`, or `gcloud auth login` → `secrets-rehydrate` once `local.keychainSecrets.backend.type = "gcp"` |
