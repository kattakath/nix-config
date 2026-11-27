# ADR-018 — Migrate the fleet from Determinate Nix to upstream Nix

**Status:** **PROPOSED 2026-11-27. Not decided, nothing changed on any host.** G1 **passed** the same day in a
disposable guest (§ 4a). This is a plan with gates. ADR-017
stays in force until every gate in § 4 passes and the operator chooses to proceed.

**Question.** ADR-017 § 3/3a found that upstream now has near-parity: `darwin.linux-builder-vz` and
lazy source copying (Nix 2.35). What would moving every host to upstream Nix take, what would we
lose, and how would we undo it?

## 1. What changes, and what we gain or lose

| | Gain | Lose |
|---|---|---|
| Linux builds on the Mac | the Caddy `cp --no-preserve=mode` failure goes away (ADR-017 § 3a); aarch64 was 2.3x faster in a single run | one more launchd daemon and disk image to own (`/var/lib/linux-builder`) |
| Store GC on darwin | nix-darwin's own `programs.nh.clean`, so `modules/darwin/store-clean.nix` can be deleted | — |
| Daemon | no closed `determinate-nixd`; no Sentry crash reports | Determinate-managed upgrades, which nix-darwin then owns through `nix.package` |
| Evaluation | — | `eval-cores` parallel evaluation (a preview), and Determinate's more aggressive lazy trees |
| Install | the default the community uses (87.5% in the 2025 survey) | the uninstaller, and surviving macOS upgrades. Both come from Determinate's installer, which since 2025-11-10 installs only Determinate Nix |

## 2. The touchpoints

Found by `git grep -l determinate` on 2026-11-27:

- **Engine:** `modules/parts/compose.nix` (both modules, `customSettings`, the builder nudge),
  `modules/parts/checks.nix`, `modules/parts/devshell.nix`.
- **darwin:** `modules/darwin/{core,github-runner,store-clean}.nix`, `hosts/macos.nix`.
- **NixOS:** `modules/nixos/{core,nix-cache}.nix` (the `install.determinate.systems` substituter and
  `/etc/determinate/config.json`).
- **Install paths:** `bootstrap.sh` (a new Mac) and the `tart-vms` capsule's `tart-vm.nix` (CI guests).
- **CI:** `nix-ci{,-impl}.yml`, `warm-nixpi-cache.yml`, `no-build-change.yml`,
  `update-flake-lock.yml` and `flakehub-publish.yml`. CI can stay on Determinate independently. It
  then tests a Nix the hosts no longer run, which is the gap `nix-ci-impl.yml` closed on 2026-09-21.
- **Inputs:** six inputs come from `flakehub.com`. That they resolve on upstream Nix is
  **unverified**; `github:` refs are the fallback.

## 3. Order: least live first

1. **nixvm** (headless, disposable) → **nixos** (the UTM VM) → **macos** → **nixpi** last.
2. Each NixOS host drops `determinate.nixosModules.default` and the `/etc/determinate` file. Its
   `nix.settings` already carry every setting (`core.nix`).
3. **macos:** `nix.enable = true`, `nix.linux-builder = { enable; package =
   pkgs.darwin.linux-builder-vz; systems = [ "aarch64-linux" "x86_64-linux" ]; }`, and
   `programs.nh.clean` in place of `store-clean.nix`.
4. **nixpi:** over the LAN (`deploy --hostname`), because the swap restarts the Nix daemon. Magic
   rollback covers a daemon that does not come back.

## 4. Gates — each must pass before the next step

| Gate | Evidence that passes it |
|---|---|
| **G1: a Mac can leave Determinate in place** | **PASSED 2026-11-27**, with manual steps both ways (§ 4a). Next: turn those steps into a script before any real Mac uses them |
| G2: the builder holds up | n ≥ 5 per cell for ADR-017 § 3a, plus the nixpi toplevel, `nixvm`, and the x86_64 devcontainer image |
| G3: FlakeHub inputs resolve | `nix flake lock` and `nix flake check --no-build` on upstream Nix in the nixvm |
| G4: CI matches | `nix-ci-impl.yml` on `cachix/install-nix-action` is green, and the loss of `eval-cores` is timed |

### 4a. G1 run, 2026-11-27

The guest was a copy-on-write clone of the runner base image (`tr-base-*`, macOS 26.6.2). It took a
VM slot through the runners' own `tart-slots.sh`, which it released afterwards, and the clone was
deleted. A minimal flake stood in for the fleet Mac: **State A** was Determinate 3.24.3 plus
nix-darwin with `determinate.darwinModules.default`, and **State B** was `nix.enable = true`,
`nix.package = pkgs.nix` and `programs.nh.clean`.

**Forward (A → B), keeping `/nix`.** nix-darwin refuses while `/usr/local/bin/determinate-nixd`
exists (`modules/system/checks.nix`: "Determinate detected, aborting activation"). So:

1. Boot out Determinate's three daemons (`systems.determinate.{nix-daemon,nix-store,nix-installer.nix-hook}`)
   and set them aside together with `/usr/local/bin/determinate-nixd`.
2. **Mount the store some other way.** The `/etc/fstab` entry is `noauto` and the volume is
   encrypted, and `determinate-nixd init` is what unlocks and mounts it at boot. Upstream's
   `org.nixos.darwin-store` daemon (as `create-darwin-volume.sh` writes it) takes over. It uses the
   `Nix Store` passphrase that Determinate's installer already put in the System keychain.
3. Move aside `/etc/nix/{nix.conf,registry.json,nix.custom.conf}` and `/etc/determinate/config.json`.
   Otherwise nix-darwin stops with "Unexpected files in /etc" and "custom settings in
   `/etc/nix/nix.custom.conf`".
4. Run `darwin-rebuild switch` with `NIX_REMOTE=local`, because no daemon is running at that point.

| Result | Evidence |
|---|---|
| Store kept | 4,358 → 4,749 paths (B's own closure added); the marker `hello` ran; `nix-store --verify` clean |
| Upstream daemon | `nix (Nix) 2.35.6`; `org.nixos.nix-daemon` running 24 s after a reboot; a new `nix build` worked |
| Boot mount | `/nix` mounted after a reboot through `org.nixos.darwin-store` |
| Locked FlakeHub input | upstream Nix evaluated the flake's locked `flakehub.com` input. That is part of G3 only, because no fresh `nix flake lock` ran |

**Rollback (B → A)** worked, with **one extra step**. After putting the files back and switching to
A, nix-darwin "restored the unmanaged Nix daemon": it left an `org.nixos.nix-daemon` plist that took
the socket, and `determinate-nixd` was not running at all. Removing that plist and kickstarting
`systems.determinate.nix-daemon` fixed it. After a reboot, `determinate-nixd` was serving again, with
4,754 paths.

**Not covered by G1:** the fleet's full macos configuration, `linux-builder-vz` under upstream
nix-darwin (a macOS guest cannot nest a Linux VM), and Determinate's own upgrade hook coming back.

## 5. Rollback

- **NixOS:** re-add the module and redeploy. On nixpi, magic rollback reverts a failed activation
  on its own.
- **macos:** the darwin generation before the switch, through `darwin-rebuild --rollback`. G1 must
  also prove that this path works, because the Nix daemon itself changes owner.

## 6. Weakest assumption

G1 has an answer: the move works without a reinstall, but only by hand, in four steps, plus one
extra step to roll back. The weakest assumption now is that **the full fleet configuration behaves
like the minimal test flake** — Homebrew, the launchd units, the Keychain loader and the Tart
runners all sit on top of the Nix daemon. A script for § 4a, rehearsed in a guest that bootstraps
the real flake (`tart-vm bootstrap --flake`), would settle it.
