# ADR-017 — Stay on Determinate Nix; one store-retention policy for the fleet

**Status:** **DECIDED 2026-11-27** (the operator chose each point click-to-select). Shipped: the
retention policy on every host (`modules/_lib/store-retention.nix`). **Corrected 2026-11-27**
(§ 3, § 3a): the first version under-rated upstream's builder and lazy trees, and § 3a measures
the builder. The verdict holds for now; ADR-018 proposes the migration.

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
| Linux builds on the Mac | **native Linux builder**: Virtualization.framework, aarch64 + x86_64, ships prebuilt, needs a free FlakeHub login | nix-darwin `nix.linux-builder` with `package = pkgs.darwin.linux-builder-vz`: Virtualization.framework, x86_64 through Rosetta, boots on demand, stops after 10 idle min (nixpkgs #544193; 26.11 release notes). Bootstraps from cache: the guest (`run-builder`) substitutes from cache.nixos.org, and only the darwin-side `create-builder` script builds locally (measured 2026-11-27: 10.5 s) | the same nix-darwin option |
| Usable with our nix-darwin setup | yes (`determinate.darwinModules.default`) | yes | yes |
| nix-darwin `nix.gc` / `nix.optimise` / `programs.nh.clean` | **unusable**: each asserts `nix.enable`, which Determinate forces off | usable | usable |
| Lazy source copying | yes, default since 3.5.2 (`lazy-trees`) | **yes, default since 2.35.0** (NixOS/nix#15711), no setting; its author calls it "slightly less lazy (but also more deterministic)" | not found (unverified) |
| Parallel evaluation | `eval-cores`, developer preview since 3.11.0 | **not shipped** (only thread-safety groundwork merged) | no |
| Daemon source | `determinate-nixd` closed (no public repo; GitHub 404) | open | open |
| Telemetry | Sentry crash reports on by default | none known | none known |
| Community share (2025 survey, multi-select) | 9.8% | **87.5%** | 14.8% |

- **Rejected for now — upstream Nix.** It would bring back nix-darwin's GC options and drop the
  closed daemon. Upstream now has near-parity on the builder (`linux-builder-vz`) and lazy copying.
  What is left on Determinate's side:
  - **Parallel evaluation**, a preview that CI's `nix flake check` uses (`nix-ci-impl.yml`).
  - **A builder with no VM of our own to run.** The `-vz` builder bootstraps from cache, but it
    is one more launchd daemon and disk image to own.
  The case is weaker than this ADR's first version said, but a migration of every host still buys
  little.
- **Rejected — Lix.** The same builder option, but its flakes work is frozen and moving to a
  plugin (Lix 2.94/2.95).
- **Weakest assumption:** that `linux-builder-vz` handles this fleet's whole workload. The spike
  below covers three workloads, one run each. ADR-018 lists what is still unmeasured.

### 3a. Builder spike, 2026-11-27

`darwin.linux-builder-vz` ran by hand from the session scratchpad, with a throwaway key and nothing
written under `/etc`. The `add-keys` step was skipped because it installs `/etc/nix/builder_ed25519`,
the same path Determinate's builder uses for its identity. Each builder had 1 CPU (vz default 3 GiB,
Determinate 16 GiB). Every workload was a fresh derivation, one run each (n=1).

| Workload | Determinate native builder | `linux-builder-vz` |
|---|---|---|
| Bootstrap | none | 10.5 s: the guest substitutes, only `create-builder` builds |
| Cold boot to SSH | — | 11.9 s, then it stops after 10 idle min |
| `hello` aarch64-linux | 26.8 s (25.7 s on a first pass) | **11.7 s** |
| `hello` x86_64-linux | 198.5 s (201.8 s) | **179.7 s**, through Rosetta (`binfmt_misc/rosetta`) |
| Caddy `cp --no-preserve=mode` repro | **fails**: `Permission denied` | **passes** |
| `checks.aarch64-linux.pre-commit` | fails: `FileNotFoundError` | not measured: `--rebuild` never dispatched to the remote builder |

- The vz builder **fixes the Caddy failure**, which is the reason a Mac-side build of a changed nixpi
  generation cannot run today (`docs/map/hosts.md`).
- On this sample it is faster on aarch64 and on par for x86_64. One run per workload is not a
  benchmark; five runs per cell would settle it.
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
