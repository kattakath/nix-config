# ADR-017 — Stay on Determinate Nix; one store-retention policy for the fleet

**Status:** **DECIDED 2026-11-27** (the operator chose each point click-to-select). Shipped: the
retention policy on every host (`modules/_lib/store-retention.nix`).

**Question.** The fleet runs Determinate Nix on every host. Should it, or should it move to upstream
Nix or Lix? And how should the Nix store be garbage-collected and optimised, so nobody has to do it by
hand?

**Trigger.** On 2026-11-27 a manual `sudo nix-collect-garbage -d` on nixpi freed **8.0 GiB** (13 GiB →
4.3 GiB used). That was in spite of a weekly `nix.gc` timer.

## 1. Verdict

- **Stay on Determinate Nix.** The Mac builds `aarch64-linux` (nixpi, the VMs) on Determinate's
  native Linux builder. The rest of the fleet's tooling depends on Determinate too (§ 3).
- **One retention policy, every host:** keep at least **3 generations**, drop anything older than
  **3 days**, run **daily**, with `nh clean all`. Each host also deduplicates as paths land
  (`auto-optimise-store`) and keeps a build-time floor (`min-free` 3 GiB / `max-free` 10 GiB).
- **determinate-nixd's own collector is `disabled` everywhere.** Determinate's best-practices page
  says not to pair it with a timer.

## 2. Why the manual GC was needed

| Fact | Evidence |
|---|---|
| nixpi's `nix-gc.timer` ran on 11-09, 11-16 and 11-23 | `systemctl list-timers` / journal on nixpi |
| Every run deleted **0 paths** | journal: `0 store paths deleted, 0.0 KiB freed` |
| Cause: the card was reflashed 2026-11-09, so no generation was older than `--delete-older-than 30d` | the generation link dates |
| The Mac had 15 system generations (744–758, oldest 11-20) | `ls /nix/var/nix/profiles`, 2026-11-27 |

The 30-day timer was only an age floor. It never bounds the generation **count**. On a host that
gets the weekly nixpkgs bump, each generation is a full new closure. **Unverified:** whether
determinate-nixd's collector prunes generations on the Mac. Its docs do not say, and the 744–758 range
could equally come from an earlier manual `-d`.

## 3. Determinate vs upstream Nix vs Lix

| | Determinate Nix 3.24.3 (both hosts) | Upstream Nix | Lix |
|---|---|---|---|
| `aarch64-linux` builds on the Mac | **native Linux builder** (needs a FlakeHub login) | nix-darwin `nix.linux-builder` | the same nix-darwin option |
| Usable with our nix-darwin setup | yes (`determinate.darwinModules.default`) | yes | yes |
| nix-darwin `nix.gc` / `nix.optimise` / `programs.nh.clean` | **unusable**: each asserts `nix.enable`, which Determinate forces off | usable | usable |
| Lazy trees / parallel eval | yes | not verified | no lazy trees (planned) |
| Daemon source | `determinate-nixd` closed (no public repo; GitHub 404) | open | open |
| Telemetry | Sentry crash reports on by default | none known | none known |
| Community share (2025 survey, multi-select) | 9.8% | **87.5%** | 14.8% |

- **Rejected — upstream Nix.** It would bring back nix-darwin's GC options. Its replacement for the
  builder, `nix.linux-builder`, is unusable only *under Determinate*; on upstream it works, but it is
  a QEMU VM with its own state, and it means migrating every host. That is a lot to pay for one GC
  wrapper, and the wrapper is cheap.
- **Rejected — Lix.** The same builder trade, and no lazy trees yet.
- **Weakest assumption:** that the native builder beats `nix.linux-builder` enough to justify the
  closed daemon. It has not been benchmarked. Measuring both on the nixpi closure would settle it.
- **FlakeHub ties** (free tier only; no paid Cache or private flakes): FlakeHub-hosted inputs
  (`determinate`, `nix`, `nixpkgs-weekly`, `nixpkgs/0.2605`, `flake-parts`, `git-hooks-nix`), the
  `flakehub-push` publish workflow, the `determinate-nix-action` / `update-flake-lock` /
  `flake-checker-action` actions, the `install.determinate.systems` substituter, `fh`, and the
  builder's login.

Sources: [determinate-nixd](https://docs.determinate.systems/determinate-nix/determinate-nixd/),
[best practices](https://docs.determinate.systems/determinate-nix/best-practices/),
[2025 community survey](https://nixos.org/surveys/community/2025/),
[installer drops upstream](https://determinate.systems/blog/installer-dropping-upstream/),
[nix-darwin README](https://github.com/nix-darwin/nix-darwin) (recommends the Lix installer).

## 4. Store retention

| Host | Mechanism | Why this one |
|---|---|---|
| NixOS (nixpi, nixos, nixvm) | nixpkgs `programs.nh.clean` (`modules/nixos/core.nix`) | the upstream option. `programs.nh.enable` stays off, so `nh os switch` (a build on the Pi) is not on its PATH |
| macos | `launchd.daemons.nix-store-clean` (`modules/darwin/store-clean.nix`) | nix-darwin's own `nh-clean` body, minus the `nix.enable` assertion. Home Manager's variant runs `nh clean user` and cannot prune system generations |

- **Both `--keep` and `--keep-since` are floors.** A busy day keeps more than 3. The same window
  prunes stale gcroots: a 2026-11-27 dry run on the Mac would remove 92 of 239, mostly nix-direnv
  roots of idle worktrees.
- **"Optimise on every activation" is `auto-optimise-store`**, not a full `nix store optimise` in
  activation. A full-store hash inside deploy-rs's confirmation window could trip a magic rollback on
  the Pi.
- **Rejected — keep nixd `automatic` and add `nh clean all --no-gc`.** That is two collectors, and
  the GC runs on no schedule.
- **Rejected — `nix.gc` with a shorter `--delete-older-than`.** It has no count floor, and on darwin it
  is unusable.
