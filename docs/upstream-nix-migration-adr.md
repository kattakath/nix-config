# ADR-018 — Migrate the fleet from Determinate Nix to upstream Nix

**Status:** **PROPOSED 2026-11-27. Not decided, nothing changed.** This is a plan with gates. ADR-017
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
| **G1: a Mac can leave Determinate in place** | On a disposable Tart macOS guest (the `tart-vms` capsule), go from a Determinate install to nix-darwin with `nix.enable = true` without reinstalling the store. **Unknown today.** Determinate's uninstaller removes `/nix` entirely, and nix-darwin's `org.nixos.nix-daemon` would collide with `systems.determinate.nix-daemon` |
| G2: the builder holds up | n ≥ 5 per cell for ADR-017 § 3a, plus the nixpi toplevel, `nixvm`, and the x86_64 devcontainer image |
| G3: FlakeHub inputs resolve | `nix flake lock` and `nix flake check --no-build` on upstream Nix in the nixvm |
| G4: CI matches | `nix-ci-impl.yml` on `cachix/install-nix-action` is green, and the loss of `eval-cores` is timed |

## 5. Rollback

- **NixOS:** re-add the module and redeploy. On nixpi, magic rollback reverts a failed activation
  on its own.
- **macos:** the darwin generation before the switch, through `darwin-rebuild --rollback`. G1 must
  also prove that this path works, because the Nix daemon itself changes owner.

## 6. Weakest assumption

That G1 has a clean answer. If the only way off Determinate on a Mac is uninstall and reinstall,
the migration costs a full Mac rebuild, and this ADR should be rejected for macos alone. The NixOS
hosts could still migrate.
