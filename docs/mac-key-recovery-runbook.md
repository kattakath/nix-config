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
equals the flake's `userName`** (reading `nix eval --raw <flake>#identity.userName`)
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
- points BOTH the `operator` and `macos` recipients in `secrets/secrets.nix` at the new
  operator key + this Mac's host key,
- **re-initialises the `macos` service secret (`gh-runner-token.age`) to a placeholder** —
  the old ciphertext is unrecoverable without the lost key (it is a revocable runner PAT),
  done with `rm` + `agenix -e` via an `EDITOR=cp` shim (agenix reads content from `$EDITOR`,
  not stdin). The still-host-decryptable `gh-runner-token-nixvm.age` and the operator-only
  `cloudflared-token.age` vault are left untouched (never `agenix -r` here — it would fail
  decrypting those orphaned blobs),
- activates `#macos`.

Afterward `key-recover` prints the finishing steps: register `~/.ssh/id_ed25519.pub` on
GitHub (authentication + signing), set the real PAT with `agenix -e secrets/gh-runner-token.age`,
commit + push, and `nix run .#key-backup` so the machine is keyed next time. Add `--fresh`
to skip the confirmation on a headless box.

## Why recovery is split in two

`bootstrap.sh` is plain bash with no dependencies, and it is the **only** part
that cannot live behind Nix: on a wiped Mac there is no Nix, so the thing that
installs Nix cannot be run by Nix. It does the irreducible minimum —

1. clear a leftover `Nix Store` APFS volume and stale `/etc` entries,
2. install Determinate Nix (curl CLI installer, **not** the `.pkg`),
3. move the installer's `/etc/nix/nix.custom.conf` aside,

— and then hands off to `nix run github:kattakath/nix-config#key-recover`,
which does everything else (decrypt → clone → agenix re-key → activate).

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

**The agenix re-key.** A reinstalled Mac has a *new* SSH host key, so the `macos`
recipient in `secrets/secrets.nix` is stale and every secret encrypted to it must
be re-encrypted. Your operator key is the other recipient, which is what lets
agenix decrypt in order to re-key at all. Note that `agenix -r` re-keys *every*
secret and age emits different bytes each time (fresh ephemeral keys), so secrets
**not** encrypted to `macos` (nixpi's `cloudflared-token`, nixvm's runner token)
come back "modified" with no semantic change; `key-recover` reverts that churn so
the commit is exactly this Mac's re-key.

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
cd ~/nix-config && git commit -m 're-key to reinstalled host key' && git push
rm -rf ~/Library/Mobile\ Documents/com~apple~CloudDocs/nix-key-recovery
```

Then empty iCloud's **Recently Deleted** (~30-day retention). The ciphertext is
strong, but a private key need not linger in iCloud once it has done its job.

Deleting the kit leaves the operator key in exactly one place: this Mac. That is
recoverable but tedious if the machine dies unexpectedly — each host can still
decrypt its *own* secret with its host key, so you could pull the plaintexts off
the live hosts and re-key to a fresh operator key. If that trade sounds bad, keep
a copy of `id_ed25519.age` somewhere durable and offline (it is still
passphrase-encrypted) before deleting the iCloud copy.

## Manual steps Nix can't do

`darwin-rebuild switch` restores everything declarative, but a few browser/GUI
one-time steps are inherently manual — do these after activating a fresh Mac:

- **Kapture Chrome extension** — the MCP gateway's `kapture` server
  (`modules/shared/mcp.nix`) is a `stdio<->WebSocket` bridge that stays **inert
  until the Kapture Chrome DevTools extension is installed** and its DevTools panel
  is open on a tab. Install it from the Chrome Web Store (extension id
  `ejfnegenodbdcodemkibocefmajjjjbn`):
  <https://chromewebstore.google.com/detail/kapture-mcp-browser-autom/ejfnegenodbdcodemkibocefmajjjjbn>.
  Nothing in Nix installs it, and the other gateway servers work without it.
- **App logins / personal tokens** — `gh` / `hf` / `docker` / `claude` one-time CLI
  logins and any Keychain-stored personal tokens are re-established by hand (Nix
  manages only the *service* secrets via agenix — see the "Secrets — agenix"
  convention in `CLAUDE.md`, not personal logins).
