# New Mac runbook

Standing up a Mac — brand new, or freshly wiped — from nothing.

## The one command — but run `--check` first on a RESET Mac

```bash
# 1. Dry run. Reports state, changes NOTHING. On a freshly-reset Mac, do this first.
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash -s -- --check

# 2. Real run.
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash
```

**Why `--check` is not optional on a reset Mac.** A macOS reset leaves the
`Nix Store` APFS volume and its `/etc` entries behind. Step 1 below deletes them
and then **reboots** — and a `curl … | bash` stream cannot resume itself, so you
finish the job by re-running the command **by hand**. So a reset Mac is a
*two-command* bootstrap with a restart in the middle, and `--check` is what tells
you that before you start rather than twenty minutes in. Read its output for:

| `--check` line | What it means for your next hour |
|---|---|
| `[STALE] 'Nix Store' volume …` | The reboot branch WILL fire. Expect two runs. |
| `[KEEP] 'Nix Store' volume … holds N bytes` | A real store, just unmounted. `sudo diskutil mount` it — do not let anything delete it. |
| `[STALE] /etc/synthetic.conf has a nix entry` | Also reboot-forcing (an `/etc/fstab`-only hit is not). |
| `[?] … root-only and sudo is not cached` | Run `sudo -v`, then re-check — it is not a "no". |
| all `[ok]`/`[note]` | Single pass, no restart. A brand-new Mac always reads this way. |

It does four things, and only the first three are irreducible:

1. clears a leftover "Nix Store" APFS volume + stale `/etc/synthetic.conf`/`/etc/fstab`
   entries from a previous install (a macOS reset leaves these behind and the
   installer then dies mounting `/nix`)
2. installs upstream Nix with the NixOS installer
   (`channels.nixos.org/nix-latest/nix-installer … install --no-confirm --enable-flakes`).
   nix-darwin's first switch renames the installer's `/etc/nix` and shell files to
   `*.before-nix-darwin` itself
3. refuses a leftover Determinate install (`/usr/local/bin/determinate-nixd`) and points at
   `scripts/nix-impl-switch.sh`
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
| `cloudflared-token.age` | Cloudflare — the `cf-tunnel-apply` app re-prints the tunnel's CURRENT connector token (a data source; `cf-tunnel-plan` first — see nixpi-tunnel.nix § ADOPTION IS IMPORT-FIRST); re-encrypt it to the new key |
| `gh-app-dontsell-ai-key.age` | GitHub App settings — generate a new private key |
| `gh-app-fleet-key.age` | the same App (identical material on purpose — rotate both together) |
| `gitlab-runner-token.age` | GitLab — re-register the runner |

## After activating, on a Mac whose old keypair is gone

1. **Generate a keypair.** `ssh-keygen -t ed25519`.
2. **Re-upload the pubkey** wherever passwordless auth is wanted — GitHub, GitLab,
   and any host you SSH to.
3. **Repoint agenix** at the new keys, from the repo root inside `nix develop`: put the
   new pubkey in `secrets/operator-key.nix`, and replace the `macos` recipient in
   `secrets/secrets.nix` with the live `/etc/ssh/ssh_host_ed25519_key.pub`. Then `rm`
   each old `.age` and re-create it with its fresh vendor value, by the `agenix -e` command in
   [`secrets-and-keychain.md`](secrets-and-keychain.md) § agenix — two vault models; for the
   `gh-app-*` pair, by the `age -R` note in `secrets/secrets.nix` instead.
   Delete first: `agenix -e` decrypts an existing file before editing, and the new key
   cannot open it. The old ciphertext is encrypted to the
   lost key and to the lost host key; it is not coming back, and does not need to.
4. **Commit and push** `secrets/operator-key.nix`, `secrets/secrets.nix` and the re-encrypted `.age` files.
5. **Finish the rotation by hand** — the steps that do NOT read `operator-key.nix` are listed in
   its own header (`allowed_signers`, and re-adding the key on GitHub as a *signing* key).

Until step 4 lands and you `activate`, `/run/agenix/*` stays empty. That does **not** block activation —
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

- **Upstream Nix via the NixOS installer** (ADR-018), the same one the Tart guests use.
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

- **App logins / personal tokens** — `gh` / `hf` / `docker` one-time CLI logins, plus one
  Claude Code `/login` per profile (`claude`, then `claude-work` as the work
  account), and any Keychain-stored personal tokens are re-established by hand (Nix
  manages only the *service* secrets via agenix — see
  [`secrets-and-keychain.md`](secrets-and-keychain.md), not personal logins).
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
- **Tart VM disks are NOT restored by a rebuild.** They live under `~/.tart/`; nothing in this repo restores them.
- **Google Takeout video shows the generic MP4 icon — re-encode with
  `media-transcode`.** Google's Storage Saver tier transcodes to
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

- **A daemon-level `nix.settings` change: check the daemon took it.** nix-darwin owns
  the daemon (`org.nixos.nix-daemon`) and `/etc/nix/nix.conf`. On a changed `nix.conf`, the
  pinned nix-darwin's `system.activationScripts.nix-daemon` sends the daemon a `HUP`
  (`modules/nix/default.nix` in that input). Whether every setting reloads on `HUP` is not
  measured here. If a setting looks ignored, restart it (needs sudo):

  ```bash
  sudo launchctl kickstart -k system/org.nixos.nix-daemon
  ```

  Determinate era (before 2026-11-27): activation never restarted Determinate's daemon, so a
  changed `trusted-users` stayed inert across two activations (measured 2026-09-15).

  **Verify BEHAVIOURALLY, never with `nix config show`.** That command reports
  the client's parse of the file, so it says "true"
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
restored — a missing one degrades silently. A row marked **Drive** has ONE copy, in the
operator's Google Drive (`Machine Config`), and its local path is a symlink into it: sign in to
Google Drive for desktop, mark that folder *Available offline* (a missing `local.inc` makes git
commit as the default identity without a word), then recreate the symlink. The **Shape** column
is for writing one from scratch.

| File | Why it is not in Nix | Shape |
|---|---|---|
| `~/.aws/config` | account ids / start-URL ids are reconnaissance; every user's differs | **Drive.** copy `~/.aws/config.example` (written by `local.cloudCli.aws`) or `aws configure sso` |
| `~/.config/git/local.inc` | which org/folder authors as which identity is the operator's alone | **Drive.** the ONE include `modules/home/default.nix` names unconditionally; holds `[includeIf "gitdir:…"]` / `[includeIf "hasconfig:remote.*.url:…"]` blocks, each `path = <identity>.inc`. |
| `~/.config/git/<identity>.inc` (each one `local.inc` routes to) | personal/work/client mailboxes | **Drive.** `[user]` + `email` (+ `name` where the identity's name differs) |
| `~/.config/git/allowed_signers` | lists every mailbox you author as | **Drive.** `<mailbox> namespaces="git" <your ssh public key>`, one line per address; signing works without it, only VERIFYING needs it |
| `~/.config/nix-config/claude-settings.overlay.json` | optional local settings | **None needed since 2026-11-01** (no private repo; client sign-ins are official connectors). Hand-place only if you want a local override, then `activate` |
| the login Keychain's secrets | never in Nix | `macos` runs `local.keychainSecrets.backend.type = "gcp"` (since 2026-10-17): `gcloud auth login` → `secrets-rehydrate`, both under `CLOUDSDK_CONFIG=~/.config/gcloud-nix-config`. Or `secret set …` by hand |
| the PGP secret key (GnuPG keyring) | a private key; it travels as a Keychain entry instead | AFTER `secrets-rehydrate`: `secret exec V=<pgp-key-entry> -- sh -c 'printf %s "$V" \| base64 -d \| gpg --import'` (find the entry with `secret ls`; swap `--import` for `--show-keys` to check the entry without importing — that is the form tested 2026-10-17; the `pgp-ops` plugin's skill carries the full procedure). `~/.gnupg/gpg-agent.conf` is DECLARED (`hosts/macos.nix`) and comes back by itself |
| `~/.config/nix-config/nixpi-wifi-roster.json` | the household SSIDs and which one is the failover are the operator's alone | **Drive** (`Machine Config/nixpi/wifi-roster.json`). `{"networks":[{"ssid":"…","role":"primary"},{"ssid":"…","role":"failover"}]}`, most-preferred FIRST; SSIDs only, PSKs stay in the Keychain. Without it `nixpi-wifi-creds`/`nixpi-provision --wifi`/`nixpi-flash` REFUSE (by design) — `packages/nixpi-provision.nix` § THE ROSTER |
| WireGuard tunnel confs | each holds a private key | **Drive**, with NO local symlink: import into WireGuard.app (or the `nixos` guest's GNOME Settings › VPN) straight from the Drive folder |
| `~/.gnupg/gpg.conf` | names the key id, and the public repo must not | **Drive.** `encrypt-to <your fingerprint>` + `default-key <your fingerprint>` — `encrypt-to` makes every message also readable by you later |
