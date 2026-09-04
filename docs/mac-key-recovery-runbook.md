# macOS key-recovery runbook

Rebuilding the `macos` host from nothing: a wiped Mac, an iCloud folder, and a
passphrase in your head.

## The kit

`nix run .#key-backup` — run this on a **healthy** Mac, *before* you wipe it. It
publishes three files to
`~/Library/Mobile Documents/com~apple~CloudDocs/nix-key-recovery/`:

| file             | what it is                                                    |
| ---------------- | ------------------------------------------------------------- |
| `id_ed25519.age` | your operator SSH key, age-encrypted under a passphrase        |
| `bootstrap.sh`   | the script you run on the wiped Mac (see below)                |
| `MANIFEST`       | non-secret: the operator key's **fingerprint**, and the date   |

Only ciphertext leaves the machine. The passphrase is typed to `age` on
`/dev/tty` and never touches a script, an argv, or an environment variable.

`MANIFEST` exists so recovery can *prove* the blob decrypted to the key it
expected before anything depends on it — a stale or swapped blob is caught
immediately instead of surfacing later as an undecryptable agenix secret.

## Recovering

After Setup Assistant and signing in to iCloud, run the curl entrypoint — it
**auto-detects** the iCloud kit, so the same command recovers (kit present) or
founds a fresh identity (no kit):

```sh
# Dry run — reports the plan, changes nothing:
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash -s -- --check

# Real run:
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash
```

Offline / air-gapped: the kit ships the same `bootstrap.sh`, so from the kit folder
`./bootstrap.sh` (or `./bootstrap.sh --check`) does exactly the same thing — it is the
byte-identical, CI-linted copy.

That is the whole procedure. It is idempotent — re-run it as often as you like.

### If the first run reboots (expected on a reset Mac)

On a Mac that was wiped/reset, the **first** run usually finds a leftover `Nix
Store` APFS volume — plus stale `/nix` entries in `/etc/synthetic.conf` and
`/etc/fstab` — left behind by the erase. It deletes them and then **reboots**,
because macOS only re-evaluates the `/nix` firmlink at boot and the Determinate
installer cannot mount `/nix` until it does. This is the designed happy path, not
a failure — output like:

```
==> Leftover 'Nix Store' APFS volume disk3s7 (24576 bytes) — from a previous/partial install
==>   deleting APFS volume disk3s7
==> Removing the stale /nix entry from /etc/synthetic.conf
==> Removing the stale /nix entry from /etc/fstab
==> A reboot is required: macOS only re-evaluates the /nix firmlink at boot.
```

means it worked. When the Mac comes back up, **run the exact same command again**.
The second pass finds a clean machine, installs Determinate Nix, and hands off to
`key-recover`. The script does **not** auto-resume across the reboot — a `curl … |
bash` stream cannot survive a restart, and nothing is installed as a login hook to
continue it — so the manual re-run is intentional, and safe to repeat.

`bootstrap.sh` installs Determinate Nix, then hands off to `nix run <flake>#key-recover`,
which **clones the flake (HTTPS — no key needed) and verifies your macOS login (`id -un`)
equals the flake's `loginName`** (reading `nix eval --raw <flake>#identity.loginName`)
*before it restores or founds any keys, or activates* — a mismatched Mac stops there
having changed nothing but a throwaway clone. A mismatch hard-fails with fork
instructions; it will not half-activate home-manager for a user that does not exist. See
the "Fresh Mac / founding mode" note below and the README "Fork this for your own fleet"
section. (`bootstrap.sh --check` runs the guard against the *remote* flake, so it warns
you of a mismatch without cloning at all.)

### Fresh Mac / founding mode (no kit)

If there is **no** recovery kit (a brand-new Mac, or you forked this repo for your own
fleet), `bootstrap.sh` runs `key-recover --fresh` — it **founds** a new identity rather
than failing:

- generates a fresh operator keypair (`~/.ssh/id_ed25519`),
- points the `operator` recipient in `secrets/secrets.nix` at the new operator key,
- leaves the operator-only `cloudflared-token.age` vault untouched (never `agenix -r`
  here — it would fail decrypting that orphaned blob, encrypted to the lost key),
- activates `#macos`.

Afterward `key-recover` prints the finishing steps: register `~/.ssh/id_ed25519.pub` on
GitHub as **both** an Authentication and a **Signing** key (the Verified badge needs
Signing — Auth alone is not enough), commit + push, and `nix run .#key-backup` so the
machine is keyed next time. Prefer the CLI (idempotent if the key already exists):

```bash
gh ssh-key add --type authentication -t "operator@$(hostname -s)" ~/.ssh/id_ed25519.pub
gh ssh-key add --type signing        -t "operator-signing@$(hostname -s)" ~/.ssh/id_ed25519.pub
# one-time: store passphrase in Keychain so login agent + git signing stay non-interactive
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Home Manager then owns the durable signing surface (`commit.gpgsign` / `tag.gpgsign`,
`gpg.format=ssh`, absolute `$HOME/.ssh/…` signingkey + `allowedSignersFile` from
`secrets/operator-key.nix` × `userEmail`, login `ssh-keychain-load` LaunchAgent).
Add `--fresh` to skip the confirmation on a headless box.

## Why recovery is split in two

`bootstrap.sh` is plain bash with no dependencies, and it is the **only** part
that cannot live behind Nix: on a wiped Mac there is no Nix, so the thing that
installs Nix cannot be run by Nix. It does the irreducible minimum —

1. clear a leftover `Nix Store` APFS volume and stale `/etc` entries,
2. install Determinate Nix (curl CLI installer, **not** the `.pkg`),
3. move the installer's `/etc/nix/nix.custom.conf` aside,

— and then hands off to `nix run github:kattakath/nix-config#key-recover`,
which does everything else (decrypt → clone → activate).

Both scripts live in this repo. `key-backup` copies `bootstrap.sh` into the kit
straight from the Nix store, so the copy sitting on the wiped Mac is byte-for-byte
the one CI shellchecked. Previously these scripts existed *only* as loose bash in
an iCloud folder — nothing linted them, nothing evaluated them, and they drifted
from the config they were meant to restore.

## The three things that actually go wrong

**A leftover `Nix Store` volume.** A macOS reset wipes the OS but leaves the
encrypted APFS volume, plus its `/etc/synthetic.conf` and `/etc/fstab` entries.
The installer then fails to mount `/nix` and dies writing its receipt
(`ReadOnlyFilesystem`). `bootstrap.sh` clears this — but note that "Nix isn't
installed" is *not* sufficient evidence a volume is stale: a healthy store that
merely failed to mount looks identical. A volume is therefore only deleted when
it is provably empty (a leftover holds ~25 KB of APFS metadata; a real store is
gigabytes) **and** you confirm. macOS only re-evaluates the `/nix` firmlink at
boot, so this stops for a reboot.

**`/etc/nix/nix.custom.conf`.** The Determinate installer writes it (a
comment-only stub). This flake sets `determinateNix.customSettings` (the Cachix
substituters), which makes nix-darwin own that exact path — and nix-darwin
refuses to overwrite `/etc` content it did not write:

```
error: Unexpected files in /etc, aborting activation
```

This is **deterministic on every fresh install**, so `bootstrap.sh` moves the
stub aside up front rather than reacting to a failed switch. The original is
kept as `.before-nix-darwin.<timestamp>`.

## Conventions worth not re-litigating

- **Determinate Nix via the curl CLI installer, never the `.pkg`.**
- **Activation goes through this flake's own `#macos` app**, so it uses the
  nix-darwin pinned in `flake.lock`. An earlier version of the kit called
  `github:LnL7/nix-darwin` unpinned and broke mid-recovery when upstream removed
  `darwin-rebuild`'s sudo self-elevation.
- **`osascript` is for notifications and confirmations only — never for
  authentication or secrets.** Privilege escalation goes through `sudo` (Touch ID,
  via `security.pam.services.sudo_local.touchIdAuth`). Routing the passphrase
  through an AppleScript dialog would move a secret through another process's
  stdout for no benefit. Every dialog degrades to a terminal prompt when there is
  no GUI session, so nothing wedges a headless run.
- **iCloud files are materialised with `brctl download`**, not by poking Finder.
  An evicted ("dataless") blob passes `[ -f ]` and *then* stalls on read.

## Afterwards

```sh
cd ~/Developer/github.com/kattakath/nix-config && git commit -m 're-key to reinstalled host key' && git push
rm -rf ~/Library/Mobile\ Documents/com~apple~CloudDocs/nix-key-recovery
```

Then empty iCloud's **Recently Deleted** (~30-day retention). The ciphertext is
strong, but a private key need not linger in iCloud once it has done its job.

Deleting the kit leaves the operator key in exactly one place: this Mac. Under
the operator-only vault only that key decrypts `secrets/cloudflared-token.age` —
no host holds a decryptable copy — so if the machine dies unexpectedly there is
no plaintext to pull off the fleet. Keep a copy of `id_ed25519.age` somewhere
durable and offline (it is still passphrase-encrypted) before deleting the
iCloud copy.

## Manual steps Nix can't do

`darwin-rebuild switch` restores everything declarative, but a few browser/GUI
one-time steps are inherently manual — do these after activating a fresh Mac:

- **App logins / personal tokens** — `gh` / `hf` / `docker` / `claude` one-time CLI
  logins and any Keychain-stored personal tokens are re-established by hand (Nix
  manages only the *service* secrets via agenix — see the "Secrets — agenix"
  convention in `CLAUDE.md`, not personal logins).
- **The `macvm` Tart guest is NOT restored by a rebuild — recreate it.** Disk lives under `~/.tart/`; neither this repo nor the key kit restores it. Recreate after recovery with `nix run .#macvm-tart-*`. Full steps: [`macvm-tart-runbook.md`](macvm-tart-runbook.md).
- **QuickLook Video's Media Extensions install disabled — enable them by hand.**
  The `quicklook-video` cask (`hosts/macos.nix`) is declarative, but what it ships
  is *not* a QuickLook generator: two **macOS Media Extensions** that plug into
  AVFoundation itself (`uk.org.marginal.qlvideo.videodecoder` and
  `.formatreader`, SDK `com.apple.mediaextension.*`). macOS registers them only
  after the bundled app is launched once, and even then they are **off** — no Nix
  or `defaults` knob flips them. Symptom if missed: video whose codec AVFoundation
  cannot decode (VP9, AV1, VC-1, RealVideo, …) shows the **generic MP4 document
  icon** in Finder with no thumbnail and no preview, while duration and dimensions
  still display — those come from the container header, not a decoded frame, which
  makes it look like a thumbnail-cache bug rather than a codec gap. Google Takeout
  exports are the usual source: Google re-encodes originals to VP9-in-MP4. Fix:
  1. `open -a "/Applications/QuickLook Video.app"` once, so macOS registers the
     extensions.
  2. `pluginkit -e use -i uk.org.marginal.qlvideo.videodecoder` and the same for
     `uk.org.marginal.qlvideo.formatreader`. Confirm with `pluginkit -mv | grep
     qlvideo` — both lines must be prefixed `+`. (System Settings → General →
     Login Items & Extensions is the GUI equivalent.)
  3. **Reboot or log out.** Media Extensions are loaded by each host process at
     launch; restarting `quicklookd` / `com.apple.quicklook.ThumbnailsAgent` and
     flushing `qlmanage -r cache` is **not** sufficient — verified.
  Verify with `qlmanage -t -s 256 -o <dir> <file.mp4>`: a PNG appears for a codec
  the extension covers, and nothing at all when the decoder is missing (the
  generator simply hangs). Note the codec table advertises VP9 as `VP9 `, while
  MP4 tags it `vp09` — if VP9 specifically still fails after a reboot, that
  mismatch is the first thing to chase.
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
  3. `determinate-nixd auth login token --token-file <(secret get FLAKEHUB_TOKEN)`
     — or write it to a temp file first if your shell doesn't support
     `<(...)` process substitution, then `rm` the file immediately after.
  4. Confirm: `determinate-nixd status` shows `Logged in: true`, and
     `determinate-nixd version` lists `native-linux-builder`.
  A stale/never-updated `determinate-nixd` binary can also hide this — the
  version this was verified against required `sudo determinate-nixd upgrade`
  first when the daemon was a patch behind.
