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
| Evaluation | — | `eval-cores` parallel evaluation: uncached `flake check` goes from **3.6 s to 17.8 s** (§ 4c). Lazy trees made no measurable difference here |
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
| **G1: a Mac can leave Determinate in place** | **PASSED 2026-11-27**: by hand on a minimal flake (§ 4a), then scripted on the real engine (§ 4b) |
| G2: the builder holds up | **PASSED 2026-11-27** at n=5 on three workloads (§ 4c). The nixpi toplevel, `nixvm` and the devcontainer image are not measured |
| G3: FlakeHub inputs resolve | **PASSED 2026-11-27** with an upstream 2.35.6 client (§ 4c) |
| G4: CI matches | **PASSED 2026-11-27**: green on upstream Nix, with the host evaluation step 50% slower (§ 4c) |

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

### 4b. Scripted rehearsal on the real engine, 2026-11-27

The repo now carries both halves, and neither changes any host by itself:

- **`local.nixImplementation`** (`modules/darwin/nix-implementation.nix`): `"determinate"` (the
  default) or `"upstream"`. With the default, every output is derivation-identical to `main`
  (`scripts/drv-snapshot.sh --compare`: ACCEPTED, run twice).
- **`scripts/nix-impl-switch.sh`**, the § 4a procedure as code:
  - It is a dry run unless given `--yes-really`, and it reads the store volume's UUID live.
  - It backs up Determinate's daemons, binary and `/etc/nix` files.
  - An EXIT/INT/TERM trap restores Determinate if anything fails after the daemons stop.
  - `to-determinate` removes the `org.nixos.nix-daemon` plist that nix-darwin leaves behind.
  - Both directions sweep the other lane's launchd units.

The guest was a fresh runner-image clone that took one VM slot (released afterwards). It ran the
engine copied from the branch, through its published template path: `lib.mkDarwin` +
`hosts/generic-darwin.nix`, with the full Home Manager profile, Homebrew and every launchd unit.
`local.upstreamLinuxBuilder = false`, because a macOS guest cannot nest a Linux VM.

| Test | Result |
|---|---|
| Dry run | plans the switch, builds the target, changes nothing |
| Injected failure right after the daemons stop (`NIX_IMPL_SWITCH_INJECT_FAILURE=after-stop`) | the trap restored Determinate. It also exposed a **bug**: the empty backup tree blocked the next run. Fixed by deleting only empty directories |
| `to-upstream`, then reboot | `/nix` mounted, upstream 2.35.6, marker intact. **Bug 1:** `nix-command`/`flakes` were off, because Determinate enables them and upstream does not. Fixed in `compose.nix`, on the upstream lane only. **Bug 2:** `nix-store-clean` stayed loaded next to `nh-clean`. nix-darwin removes only what `/run/current-system` lists, and the guest's earlier half-failed activations had left that link stale. The script now sweeps it |
| `to-determinate`, then reboot | `determinate-nixd` serving, no leftover `org.nixos.nix-daemon`, backup cleared |
| Clean `to-upstream` with every fix, then reboot | one command. 7,712 paths kept, marker runs, a new build works, `nix-store --verify` clean |

**Still not covered:**
- `hosts/macos.nix`: agenix, the CI runner lanes, `masApps`.
- `linux-builder-vz` running as a nix-darwin service.
- A Mac with months of state.

### 4c. G2, G3, evaluation and a dry run on the real Mac, 2026-11-27

- **G2:** every cell repeated five times, with a tight spread. vz was faster on aarch64 (10.1 s
  against 26.1 s) and on x86_64 (177.4 s against 197.9 s). The Caddy repro passed 5/5 on vz and
  failed 5/5 on Determinate. Full table: ADR-017 § 3a.
- **G3:** run with an upstream 2.35.6 client on a detached `origin/main`, against the same
  daemon:
  - `nix flake update determinate nixpkgs` re-resolved both FlakeHub root inputs: exit 0.
  - `flake metadata`: exit 0.
  - `flake check --no-build --all-systems --option eval-cache false`: exit 0.
- **Evaluation cost of leaving:**

  | Client (uncached `flake check --no-build --all-systems`, n=2–3) | Time |
  |---|---|
  | Determinate, default (`eval-cores` = all 12 cores) | **3.5–3.8 s** |
  | Determinate, `eval-cores = 1` | 11.1 s |
  | Determinate, `lazy-trees = false` | 3.6–3.8 s |
  | upstream 2.35.6 | 17.7–17.8 s |

- **Dry run on the real Mac:** the script ran without `--yes-really`, against `#macos` with
  `local.nixImplementation = "upstream"` on a branch that was never pushed.
  - The target system built.
  - It read this Mac's own volume UUID and found its `Nix Store` keychain item.
  - It stopped at "would run".
  - The target differs from today's system in launchd units only: it adds `linux-builder`,
    `nh-clean` and `nix-daemon`, and drops `nix-store-clean`.
  - There were no evaluation warnings.

- **G4:** `nix-ci`, dispatched on a throwaway branch (deleted afterwards) whose only change was
  `cachix/install-nix-action` v31 (the pin used before 2026-09-21) in place of
  `determinate-nix-action`. Every job was green ([run 46090639799](https://github.com/kattakath/nix-config/actions/runs/46090639799)). Against the
  last green Determinate run on `main` (46086327781), n=1:

  | `build (aarch64-linux)` step | Determinate | Upstream |
  |---|---|---|
  | Install Nix | 7 s | 3 s |
  | Build checks + push to Cachix | 44 s | 48 s |
  | **Evaluate host configs (no build)** | **40 s** | **60 s** |
  | Whole job | 103 s | 120 s |

**All four gates have passed.** The cost of leaving is evaluation speed: about 14 s per local
`flake check` and about 20 s per CI run. The decision to migrate is the operator's.

## 5. Rollback

- **NixOS:** re-add the module and redeploy. On nixpi, magic rollback reverts a failed activation
  on its own.
- **macos:** `sudo scripts/nix-impl-switch.sh to-determinate --flake <ref#host> --yes-really`, with
  the host's flag set back to `"determinate"`. Rehearsed in § 4b. A bare `darwin-rebuild --rollback`
  is **not** enough: it was never tested, and it cannot restore Determinate's daemons, which live
  outside any generation.

## 6. Weakest assumption

The move works without a reinstall, and it is now scripted and rehearsed on the real engine (§ 4b).
The weakest assumption is that **`hosts/macos.nix` and months of real state behave like the
rehearsal guest**. The agenix activation, the two CI runner lanes and a store that has run for
months were not in the guest. The closest settling evidence is a dry run of the script on the real
Mac, which changes nothing.
