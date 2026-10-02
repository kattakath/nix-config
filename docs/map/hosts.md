Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `hosts/` — per-host entry profiles

**`macos` carries ONE account.** `ismail` is `system.primaryUser` and owns the operator
profile. A second ADMINISTRATOR account (`izzy`, uid 502) lived here from 2026-09-15 to
2026-09-17 and was then **deleted forever** — account, home directory, per-user casks
(Opera/CapCut/Audacity) and FileVault enrolment. Three things it taught outlive it, because
they bite any future second account:

- **`users.knownUsers` is the DELETE switch, and deleting is NOT "remove the name".**
  Measured 2026-09-17, against the pinned nix-darwin `modules/users/default.nix:26`:
  `deletedUsers = filter (n: isDeleted cfg.users n) cfg.knownUsers` — a user is deleted only
  while its name is STILL in `knownUsers` and its `users.users.<name>` entry is GONE. Drop
  both at once (the intuitive spelling) and nix-darwin simply stops knowing the account:
  activation exits 0, says nothing, and the account survives. To retire one declaratively,
  delete `users.users.<name>` first, activate, THEN drop the name from `knownUsers`. It also
  refuses any uid ≤ 501, and it removes the directory RECORD only — the home directory,
  `admin` group membership and FileVault enrolment are all left behind. `isHidden` likewise
  defaults `true` and is applied ONLY at creation, so flipping it later needs a converge shim.
- **Homebrew `args.appdir` only applies at INSTALL time**, and `brew bundle` runs as
  `homebrew.user` under sudo — so a per-user cask directory is created `root:staff 0755` and
  the owning account's own Home Manager then dies with EPERM on its `~/Applications` symlink.
- **A never-logged-in account blocks activation, SILENTLY.** A user launchd agent can only
  bootstrap into that user's own GUI session, so any agent declared for an account that has
  never logged in fails with `Bootstrap failed: 125: Domain does not support specified
  action`. Home Manager's activation then exits non-zero and **nix-darwin's own**
  `$systemConfig/activate` — not the `activate` CLI — runs under `set -e`, so the abort lands
  ~80 lines short of its final `ln -sfn … /run/current-system`. The system **profile**
  advances while `/run/current-system` and `/nix/var/nix/gcroots/current-system` stay on the
  OLD generation — and `/run/current-system/sw/bin` is what PATH resolves. Packages end up
  installed and unreachable at the same time.

  **`darwin-rebuild` exits 1.** MEASURED 2026-09-15 by re-enabling one such agent and
  capturing the status with no pipe (`> file 2>&1; RC=$?`): broken run 1, healthy run 0.
  Every link propagates — `setupLaunchAgents` returns 1 (pinned home-manager
  `modules/launchd/default.nix:564`), the generation's `activate` then does
  `exit "$launchdStatus"`, `launchctl asuser` passes a child status through (verified: a child
  exiting 7 yields 7), and `$systemConfig/activate` is `darwin-rebuild`'s last statement under
  `set -e`. Cite that one by CONSTRUCT, not line: the generation's `activate` is GENERATED per
  user per generation, and the same `exit` sat at 833, 848 and 936 across three of them on one
  afternoon. The pinned-input citations around it (`modules/launchd/default.nix:166`, `:232`,
  `:326`, `:564`) are the opposite case and stay — a `/nix/store` flake input only moves on a
  `flake.lock` bump, which is a reviewed event, and that is the same basis
  [`upstream-first`](../../.claude/rules/upstream-first.md) already requires citing. **The rule is
  not "no line numbers" — it is "no line numbers into generated artifacts."**

  So it is not silent for lack of a signal — it is silent because **nobody reads the exit code
  of an interactive activation**, and because a status read through a pipe
  (`activate | tail`) is the PIPE's, not the command's. That misreading is exactly how an
  earlier revision of this paragraph came to claim exit 0. It is the same family as the
  `cmd | grep -q` trap that returns 141 on a SUCCESSFUL match under `pipefail` (§ Home Manager
  activation): **a status taken through a pipe describes the pipe.**

  The obvious fix is itself a trap, and this fleet hit all three rungs of it. `$PIPESTATUS`
  is a BASH array; in zsh — the login shell here — it does not exist, so **every** index
  expands to the empty string, not just `[0]`. zsh's array is lowercase `$pipestatus` and is
  1-indexed. And either array is destroyed by the next COMMAND that runs — an assignment
  counts, a newline does not. Measured:

  ```
  sh -c 'exit 3' | cat; LO=("${pipestatus[@]}")   # -> (3 0)   correct
  sh -c 'exit 3' | cat; UP=("${PIPESTATUS[@]}")   # -> ()      empty at EVERY index
  sh -c 'exit 5' | cat
  echo "(${pipestatus[@]})"                       # -> (5 0)   survives a newline
  sh -c 'exit 7' | cat
  : ; echo "(${pipestatus[@]})"                   # -> (0)     one no-op command destroys it
  ```

  So the rule is **capture before anything else runs**, not "same line" — reading it on the
  following line works, because the expansion happens while building the next command's
  arguments rather than after that command has run. Same line, lowercase first, nothing in
  between is simply the version that cannot go wrong.

  So the rule is not "use `[1]`" — that still yields nothing in zsh and still reads as a pass.
  Either do not pipe (`cmd > /tmp/out 2>&1; RC=$?`, then read the file) or use lowercase
  `${pipestatus[1]}` captured immediately. **A bare `EXIT=` in your output is a BROKEN PROBE,
  not a passing one** — an empty status reads as "no failure" when it means "the instrument
  returned nothing".

  Diagnose by comparing
  `nix eval .#darwinConfigurations.macos.system` against `readlink -f /run/current-system`;
  the system profile is NOT the authority here. (It stranded four generations deep before
  anyone noticed, 2026-09-15.)

  **`launchd.enable = false` does not fix it — it is a no-op.** The option reads like the
  class-wide switch, but upstream uses `cfg.enable` in exactly one place, an assertion
  (pinned home-manager `modules/launchd/default.nix:232`): `agentPlists` filters on the
  PER-AGENT flag (`:166`) and `home.activation.setupLaunchAgents` is gated on `isDarwin`
  alone (`:242`). Measured — it evaluated `false` and both agents still bootstrapped. The
  working spelling is `launchd.agents.<name>.enable` (`:20`), and it needs `lib.mkForce`
  because the agents are unconditionally `true` at their source.

  Removal is safe on a domain-less user even though installation is not: `bootoutAgent`
  whitelists that same error (`:326`) where `bootstrapAgent` treats it as fatal — which is
  why the per-agent `false` works at all.

  The cost is upstream's per-agent design: every agent added to `modules/home/default.nix`
  would have to be listed again in such an account's block, or its activation starts
  aborting anew.

- **`macos.nix`** — the darwin client host. Imports `../modules/darwin/github-runner.nix` and
  enables `local.macosGithubRunner` with `count = 2` for the **`dontsell-ai`** org (see that
  module's section below) — nix-config's *own* CI is fully GitHub-hosted and uses no runner, but
  this Mac is not runner-free. Also configures **`local.tart.githubRunners.*`** (the `tart-vms` capsule's
  `darwinModules.github-runner`, in `mkDarwin`'s BASE module list): ephemeral **Tart-VM-per-job**
  GitHub Actions runners for `kattakath`, `silvercreek-ai`, and `dontsell-ai` (label
  `dontsell-vm` — the bare-metal pair keeps that org's nix-toolchain CI), one fleet GitHub App
  (`ismailkattakath-ci`, appId 4849830 — it replaced the retired `kattakath-fleet-ci` on
  2026-09-06; key = agenix `gh-app-fleet-key.age`, host-decrypted), digest-pinned
  Cirrus runner image, and Apple's 2-concurrent-VM budget shared by a slot semaphore. The base
  clone and the host-key pin are content-keyed by `oci@digest`, so a digest bump renames both;
  one elected instance per image re-pulls and re-pins itself on its next cycle
  (`tart-runner-setup-kattakath [image|pin|all]` pre-warms that by hand). Slots, pins and both
  lanes' logs live under `local.tart.runnerStateDir` — `~/.local/state/tart-runner` by default,
  durable and user-writable; a volatile root now fails at eval, after the old `/tmp` default
  was purged and darked all three lanes on 2026-09-05. The **GitLab** runner shares the
  same VM budget declaratively since 2026-09-05: **`local.tart.gitlabRunner`** (the same capsule's `gitlab-runner.nix`,
  same base list) runs `pkgs.gitlab-runner` as a GUI LaunchAgent that renders its `config.toml`
  at start from the agenix `gitlab-runner-token.age` (host-decrypted), pointing at the
  `gitlab-tart` slot shims around cirruslabs' first-party executor — the semaphore
  (`modules/features/tart-vms/packages/tart-slots.nix`) is the single protocol both forges speak; only runner
  *registration* (minting the glrt- token) remains manual. Carries its own Homebrew brew/cask/masApps lists, incl. a
  `libreoffice` cask backing the docx/pptx/xlsx/pdf Claude Code skills' `soffice` dependency,
  and the `open-design` cask (`greedy = true`, adopted the hand-dragged app in place) paired
  with `launchd.user.envVariables.OD_UPDATE_ENABLED = "0"` so versioning belongs to brew, not
  the app's drift-prone self-updater — the full declared/imperative boundary is
  [`open-design.md`](../open-design.md). Also imports `../modules/darwin/claude-managed-settings.nix`
  and sets `local.claudeManagedSettings.enable = true` — the root-owned Claude Code policy tier
  (§ `modules/darwin/`); it is the only host that has one. Consequence worth recognising when it
  fires: a PRE-EXISTING unowned `managed-settings.json` (an MDM payload, a hand-placed file)
  now FAILS activation with exit 2 rather than being clobbered.
- `macvm.nix` — removed 2026-09-05 with the rest of the `macvm` Tart guest; re-add path:
  [`macvm-readd-runbook.md`](../macvm-readd-runbook.md).
- **`nixpi.nix`** — Pi 4, LIVE: boot fixes + cloudflared + upstream `services.caddy`. Its
  `sdImage` is prebuilt in CI and published to the `installer-latest` release, since it bakes
  no secrets.
  - ⚠ **The Mac's native Linux builder cannot build this host's `etc` closure.** Upstream's
    caddy module formats the generated Caddyfile in a `Caddyfile-formatted` derivation whose
    build command is `cp --no-preserve=mode <Caddyfile> $out/Caddyfile`, and **`cp
    --no-preserve=mode` into `$out` fails with `setting permissions: Permission denied`** on
    Determinate's native Linux builder (reproduced minimally with
    `runCommand "p" {} "mkdir -p $out; cp --no-preserve=mode ${writeText "s" "x"} $out/f"`; a
    plain `chmod` in `$out` on the same builder works). That failure cascades to `etc.drv` and
    the toplevel, so **any** Mac-side build of a Caddy-serving nixpi generation dies. Upstream
    already skips the derivation when `buildPlatform != hostPlatform`, which does not help here
    (both are `aarch64-linux`). Measured 2026-09-15: **only that one operation fails** — `cat >`,
    `install -m` and `cp` + `chmod` all succeed on the same builder, so this is a narrow,
    undocumented, unreported builder bug rather than a general chmod ban.
    - **THE ANSWER IS NOT TO BUILD ON THE PI.** That was the old workaround, and it is now
      hard-blocked (`.claude/hooks/pretooluse-bash-guard.js` Rule 1d): the Pi is on an SD card,
      and a power cut mid-build corrupts it, which needs hands on the hardware to reflash.
      Instead `.github/workflows/warm-nixpi-cache.yml` builds the toplevel on a real
      `ubuntu-24.04-arm` runner — where that `cp` works — and pushes the closure to Cachix on
      every nixpi-closure change. Both the Mac and the Pi then substitute, and the EPERM never
      enters the path.
    - **The EPERM only fires on a cache MISS**, and a miss can OUTLIVE the warm: if you
      evaluate a nixpi change before CI has pushed it, Nix records the 404 in its narinfo
      negative cache for an hour (`narinfo-cache-negative-ttl`, default 3600), so it keeps
      planning a build against an already-warmed cache. **You cannot clear that from the CLI**
      — the operator is `Trusted: 0` against the local daemon, so `--narinfo-cache-negative-ttl 0`
      is answered with *"ignoring the client-specified setting … you are not a trusted user"*
      (same reason `--builders`/`--max-jobs 0` are ignored). Wait it out, or add the operator to
      `determinateNix.customSettings.trusted-users`.
- **`nixvm.nix`** — a SLIM, unprovisioned aarch64-linux dev VM: no disko, no runner, no
  install; materialised only as the graphical `nix run .#nixvm` build-vm, whose guest builds
  locally on the native Linux builder or substitutes from Cachix.

  **Disposable, NOT ephemeral — and the split is per-filesystem.** `useNixStoreImage = true`
  makes the guest's Nix *store* an erofs image rebuilt into `$TMPDIR` on every boot, so store
  state genuinely does not survive. The *root* filesystem does. Nothing in this repo sets
  `virtualisation.diskImage`, so it is nixpkgs' default `"./${config.system.name}.qcow2"` —
  and qemu-vm.nix `readlink -f`s that at line 129, **156 lines before** it `cd`s to `$TMPDIR`
  at line 285, so a bare relative default resolves against the CALLER'S working directory.
  Line 131 then creates the image only `if ! test -e`. Consequences: `/home` and everything
  outside `/nix` survives reboots; the reset is `rm` on the qcow2, nothing in Nix; and
  **`diskSize` is a create-once ceiling** — raising it does not grow an existing image,
  because `createEmptyFilesystemImage` sits inside that absence guard. `*.qcow2` is
  gitignored, so an image left in the repo root cannot be swept into a commit.

  **`nix run .#nixvm` does not inherit the CWD binding.** Its app is a wrapper
  (`modules/parts/packages.nix`) that creates a 0700 XDG state dir and exports
  `NIX_DISK_IMAGE` — upstream's own override hook at that same line 129 — so the flake app
  always boots the SAME VM from anywhere, instead of growing one root disk per directory it
  was invoked from. Same root cause, and same fix shape, as the OpenTofu state this repo lost
  twice to running in whatever the CWD happened to be (`modules/parts/terranix.nix`). The
  per-CWD default is still what a hand-run `./result/bin/run-nixvm-vm` gets, which is why the
  option itself is left alone.

  `diskImage = null` would make the root a tmpfs and the VM truly stateless (nixpkgs' own
  option doc: *"the VM's state will not be persistent"*). Deliberately not done — a dev VM
  that loses your scratch work on reboot is the wrong default; it would also put the whole
  desktop session in guest RAM.

  The **base** (non-`vmVariant`) config has no `virtualisation.diskImage` at all, because
  qemu-vm.nix is imported only by the VM variant. It exists purely so the toplevel evaluates
  in CI and `build.vm` has a coherent substrate; there is no headless `nixvm` you can boot.

## Building `aarch64-linux` on the Mac, and deploying `nixpi`

The long form of CLAUDE.md § Important Notes. Those bullets keep the imperatives; the
measurements that justify them live here, because they are read once and obeyed thereafter.

### The native Linux builder

`aarch64-linux` builds on the Mac go to **Determinate's native Linux builder** (Apple
Virtualization; an ephemeral VM, **1 CPU / 8 GiB by default**). The account entitlement is
enabled at <https://dtr.mn/features>.

It serves **`x86_64-linux` too.** The rendered `external-builders` entry names both systems,
and an `x86_64-linux` derivation built here returns `uname -m` = `x86_64` (measured
2026-09-22) — a real second platform, not an idle advertisement. That is what lets
`packages.x86_64-linux.devcontainerImage` build on this Mac and not only in CI. It does
**not** dent the aarch64-only invariant: that claim is about **hosts** (§ The fleet), and a
build-only ephemeral sandbox is not one.

#### It does NOT share Tart's two-guest budget

`local.tart.runnerSlots` is a filesystem semaphore under `local.tart.runnerStateDir/slots`
([`slots.nix`](../../modules/features/tart-vms/slots.nix)), entered only by the two CI lanes'
shims; `determinate-nixd` has no code path to it. Measured 2026-09-22: **four** builder VMs
ran concurrently while that directory held **zero** slot markers. The cap the semaphore
exists to share is specifically on concurrent **macOS** guests (`github-runner.nix`'s
assertion says so in those words), so a Linux builder guest sits outside both accountings.

Still unmeasured: two Tart macOS guests **plus** a builder VM. Four concurrent Linux guests
prove the cap is not a global VM cap, which makes a collision unlikely — but nobody has
booted the mixed case, so treat it as untested rather than safe.

The axis that IS shared is **host RAM**, and nothing bounds it: `max-jobs` is `12` here
(Determinate raises it to nproc; this repo sets it nowhere), so one `nix build` may start
twelve guests at 8 GiB each. Less dire than that arithmetic — Virtualization backs guest
memory lazily, and 66% of 36 GiB was still free with three such VMs live — but the ceiling is
untested, and a wide parallel build alongside two 8 GiB Tart guests is the case to watch.

The VM **is** settable from Nix: the pinned `determinate` module grew
`determinateNix.determinateNixd.builder.{state,memoryBytes,cpuCount}`, rendered to
`/etc/determinate/config.json`. Only the raw `external-builders` line is reserved and rejected
by `customSettings`. Upstream says do **not** change `cpuCount`; `memoryBytes` is the knob if a
Linux build ever OOMs.

nix-darwin's own `nix.linux-builder` is unusable here: it requires `nix.enable = true`, which
Determinate disables (nix-darwin#1505).

**Account entitlement alone is not enough.** The local `determinate-nixd` must ALSO be logged in
to FlakeHub, or `native-linux-builder` silently vanishes and every `aarch64-linux` build fails
with a `platform mismatch` that reads as a platform problem rather than an auth one. It is a
manual, per-machine step — see "Manual steps Nix can't do" in
[`new-mac-runbook.md`](../new-mac-runbook.md).

#### The one operation it cannot do

The builder **cannot run `cp --no-preserve=mode` into `$out`** — EPERM, "setting permissions".
That breaks nixpkgs' caddy `Caddyfile-formatted`, and therefore every Mac-side build of a
Caddy-serving `nixpi` generation.

Measured 2026-09-15: **only that one operation fails.** `cat >`, `install -m`, and `cp` followed
by `chmod` all succeed on the same builder. So this is a narrow (undocumented, unreported)
builder bug, not a general chmod ban — which matters, because the tempting diagnosis is "the
builder can't set permissions" and that would send you looking for a fix that does not exist.

**Do not work around it by building on the Pi.** `warm-nixpi-cache.yml` builds the closure on a
real ARM Linux runner and pushes it to Cachix, so the Mac substitutes and never runs that `cp`
at all. Heavy multi-core builds (the Pi SD image) go to GitHub CI / Cachix for the same reason.

### What magic rollback actually buys

`deploy.nodes.nixpi.magicRollback = true`: the Pi activates behind a watchdog and reverts
**itself** to the previous generation unless the deployer reconnects over a second ssh session
and confirms.

That converts the fleet's worst failure into an ordinary one. A change that kills sshd, the
tunnel connector, or networking becomes a **failed deploy** instead of a trip to the shelf to
pull the SD card and reflash ([`nixpi-sd-flashing-runbook.md`](../nixpi-sd-flashing-runbook.md),
~40 min with hands on the hardware).

`nixos-rebuild switch --target-host` has **no such undo** — it is the faster command and the one
with no safety net. `remoteBuild = false` keeps the build off the Pi either way.

**Anecdote:** it is the climber's rope. It does not stop the fall; it stops the fall from being
the end of the trip. *(Where it breaks down: the rope is anchored to the deployer's second ssh
session — lose your own connectivity mid-deploy and the Pi rolls back a change that was
perfectly fine.)*

