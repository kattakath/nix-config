Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `modules/darwin/`

`modules/darwin/{core.nix,user-folders.nix,homebrew.nix,nix-homebrew.nix,xcode-license.nix,launchd-reconcile.nix,logging.nix,github-runner.nix,ollama-daemon.nix,claude-managed-settings.nix}`

- **`core.nix`** — macOS system defaults (dock/finder/NSGlobalDomain, Touch ID for sudo,
  `stateVersion = 5`), plus the GUI `PATH`/`BASH_ENV` `launchd.user.envVariables` and the
  post-activation Dock refresh that makes them reachable. `screencapture.location` is unset
  everywhere (the shared-inbox override left with the `macvm` guest, 2026-09-05), which is
  what makes `~/Desktop` the capture inbox the sweeps rotate.
  **It declares no launchd AGENT any more.** The Maccy opener and the two `mkTrashSweep`
  rotations left for the home-manager lane on 2026-10-02 — see
  `modules/home/macos-user-agents.nix` above. With the `tart-vms` CI runners moved the same
  week, **nothing composed on `macos` is left on `launchd.user.agents` at all**, and
  `checks.<system>.launchd-selfheal-lane` gates that emptiness as its first leg rather than
  only naming the five Labels. The one place the option is still WRITTEN is
  `modules/features/tart-vms/darwin.nix` (`local.tart.vms.*`), which reaches no host:
  `modules/parts/compose.nix` inherits only the two runner lanes from that capsule, so
  `local.tart.vms` is not even a declared option on `macos`. It moves with the re-add
  [`macvm-readd-runbook.md`](../macvm-readd-runbook.md) plans.
- **`user-folders.nix`** — the `local.folders.{desktop,downloads}` options: unset = the
  macOS system default (`~/Desktop`, `~/Downloads`), override = the relocation seam; an
  invalid (non-absolute) value fails loudly at eval rather than silently falling back.
  Consumed through `osConfig` by `modules/home/macos-user-agents.nix`'s sweeps (they left
  core.nix on 2026-10-02) — folder paths are never re-derived inline, and the option stays
  declared in the nix-darwin layer because the paths are a macOS system fact and a
  home-manager copy of the default would be the second source of truth it exists to
  prevent.
- **`homebrew.nix`** — the declarative Homebrew **framework**: owns only
  `enable`/`onActivation` with `cleanup = "uninstall"`/`taps`. The actual
  `brews`/`casks`/`masApps` lists live **per host** in `hosts/<host>.nix` so each darwin
  host carries its own app set.
- **`launchd-reconcile.nix`** — option-free. Brings back a `launchd.daemons` unit that has left
  the system domain, at the next activation **and** the next boot. Exists because nix-darwin's
  launchd activation is **diff-gated** (`modules/system/launchd.nix:19`): an unchanged plist means
  the reload body never runs, so an absent daemon is never re-bootstrapped — upstream #1199, and
  the hole Home Manager does **not** have (it probes `launchctl print` and re-bootstraps,
  `modules/launchd/default.nix:411-419`). That is why 22 user agents stayed healthy through the
  2026-09-22 outage while `activate-agenix` and both `github-runner-macos-*` daemons sat outside
  the domain for ~21h, taking `/run/agenix` — and so all three host-decrypted secrets and five CI
  lanes — with them. The preserved launchd ring held 24k `org.nix` lines across four activations
  that day and, for those three labels, only `Could not find job with label …`; never a spawn.
  `launchctl load`'s exit code is documented as meaningless, so each of those activations reported
  success. `ollama-daemon.nix:212` records the same class costing 10h52m earlier.
  **Two hooks, deliberately.** `postActivation` covers `darwin-rebuild switch` — *not*
  `activationScripts.launchd` (upstream `openssh.nix:115`'s phase), because
  `activation-scripts.nix:128-140` orders `launchd → userLaunchd → … → postActivation` and
  reconciling last never races a plist the same run is still writing. `launchd.daemons.activate-system.script`
  (`mkAfter`; `script` is `types.lines`) covers **boot**, because the boot daemon runs only
  `checks`, `etc` and `keyboard` (`services/activate-system/default.nix:68-70`) — a switch-only fix
  leaves the next reboot broken. Merging into upstream's own `RunAtLoad` daemon also inherits its
  sanctioned `/bin/sh -c wait4path` arg0, so the boot half is mount-protected for free.
  **Not a supervisor**: two launchctl verbs in an idempotent probe, reusing the `enable` +
  `bootstrap` idiom nix-darwin already ships in `services/openssh.nix:115-116`. Not `kickstart` —
  that only restarts a job **already** in the domain (`karabiner-elements/default.nix:44`) and
  cannot bootstrap an absent one. Escape hatch: touch `/etc/nix-darwin/launchd-hold/<label>` and
  the reconciler skips it, so a deliberate `bootout` survives the next activation. The disabled DB
  cannot serve as that signal — `bootout` does not write it, and all six labels read `=> enabled`
  while three were absent.
- **`packages/rogers-gw.nix`** (app `nix run .#rogers-gw`) — ad-hoc **inspection-only** CLI for
  the household's Rogers CGM4981 (RDK-B) gateway, which exposes no shell: 22/23 are closed and
  161 does not answer, so its web UI is the only management surface and its log table comes from
  a JSON endpoint the "Show Logs" button never even requests. Reads `ROGERS_GW_PASSWORD` from the
  login Keychain via `secret exec`, never from argv. **It must stay inspection-only** — the
  customer-facing log carries only OneWifi entries, and the fleet already has a strictly better
  "is the WAN up" signal in the Cloudflare tunnel to nixpi, observed from outside the house. The
  wire contract, cited against the Apache-2.0 `rdkcentral/webui` firmware source, is
  [`docs/rdkb-gateway-contract.md`](../rdkb-gateway-contract.md) — read it before changing anything.
- **`packages/launchd-doctor.nix`** (app `nix run .#launchd-doctor`) — runtime health check for
  every launchd unit this fleet installs. Covers what **cannot** be a flake check, because every one is a
  property of the running machine rather than the evaluated config: **declared but not loaded**
  (plus non-zero last-exit, which catches the exit-78 boot/mount class), **loaded but not
  declared**, unrotated log growth, and the litter left by removed features in launchd's
  disabled DB and `~/Library/Logs`.
  The **loaded-but-not-declared** half is the inverse of the first and needs its own check.
  nix-darwin retires a user agent by scanning `/run/current-system/user/Library/LaunchAgents`
  and deleting whatever the new generation lacks (`modules/system/launchd.nix:150-161`) — a
  **single-transition** mechanism that only ever sees the one generation boundary where the
  agent disappeared. Miss it and the plist is orphaned **permanently**, because the directory
  the loop scans no longer lists it either. `org.nixos.open-docker` survived exactly that way
  on 2026-09-22, kept running `open -a Docker` against an app deleted six days earlier, and
  was caught only incidentally by its non-zero exit — an orphan exiting 0 would have been
  invisible. The two halves also disagree on the remedy, so the first consults the generation
  manifest before offering `bootstrap`: telling the operator to start a plist no generation
  declares would resurrect something deliberately retired. **No Nix-time threading**, same contract as
  `claude-otel-doctor.nix` — the installed plists ARE the declared set, and threading a Nix
  manifest in would make the doctor agree with the config by construction, which is the one
  thing a drift check must not do. Read-only: it prints remedies, never runs them. Wired as
  step E3 of the `fleet-doctor` skill, under **always confirm** — bootstrapping a daemon the
  operator deliberately booted out is exactly the wrong move.
- **`logging.nix`** (macos only) — rotation for **every launchd log this fleet declares**,
  off the **four** composed sources, which it **imports from `launchd-sources.nix` rather
  than enumerating** (2026-10-02: it was the **third** copy of that list, beside
  `launchd-reconcile.nix` and `modules/parts/checks.nix`). **Tier is `domain`, not a fifth
  field** — the `gui` sources are the login-user tick and the `system` source is the root
  tick, which is how `checks.<system>.launchd-log-rotation` already read it; the mapping is
  sound in the direction that matters, since a `launchd.daemons` unit that set `UserName`
  would still land on the root tick, and root can truncate any owner's file. Two mechanisms,
  because macOS gives two different physics.
  **Mechanism 1 — the logs that re-exec:** `system.newsyslog.{enable,files}` (pinned
  `modules/system/newsyslog.nix:11-160`, registered `module-list.nix:45`). Upstream, and
  **never used by this fleet** until 2026-09-22 — which is how `~/Library/Logs` reached
  **231 MB**. launchd opens `StandardOutPath` **once at spawn** and hands the fd to the child;
  macOS `newsyslog` does rename+create and has **no `copytruncate`** (`man 5 newsyslog.conf`:
  flags are `B C D G J N U Z` only), so this works only where the process genuinely re-opens
  the path on its next spawn. Its win over mechanism 2 is that it is **lossless**.
  **Mechanism 2 — the long-lived (`KeepAlive`) logs:** `pkgs.logrotate` with its own
  `copytruncate` directive, on an hourly `StartInterval` tick — one as a **Home Manager**
  agent (`file-rotation-logs`), one as a root daemon (`file-rotation-logs-system`, because a
  login user cannot truncate `/var/log`).
  **Why the user tick is a Home Manager agent and not `launchd.user.agents`:** the same move
  `metube`/`yt-dlp-web-ui` made on 2026-09-22. nix-darwin's user-agent activation is
  diff-gated (pinned `modules/system/launchd.nix:36`) and `launchd-reconcile.nix` filters
  `config.launchd.daemons` only, so a nix-darwin user agent that leaves its launchd domain has
  an unchanged plist and is skipped by every later activation — the rotator stops, the logs it
  covers grow unbounded, and **no check can go red**, because a flake check cannot observe a
  launchd domain. Home Manager probes with `launchctl print` and re-bootstraps. The root tick
  stays nix-darwin (Home Manager has no root tier) and `launchd-reconcile.nix` covers it.
  **Which tick owns a path is decided by writability, not authorship:** any path **a daemon
  declares in either bucket** goes to the root tick, everything else to the user tick. Without
  that rule, a path classified long-lived by a user agent but owned by root would leave the
  newsyslog set globally and land on a login-user `logrotate` that gets EPERM — covered on
  paper, reclaiming nothing. `checks.<system>.launchd-log-rotation` asserts it independently —
  it re-derives the daemon-declared set and compares it against the module's *answer*, so a
  broken tier rule in `logging.nix` still goes red (verified: replacing
  `userLongLived = lib.subtractLists daemonDeclared allLongLived` with `allLongLived` fails the
  EPERM leg with five root-owned `/var/log` paths named).
  **One enumeration costs one kind of detection, and the gate pays it back explicitly.** While
  the four sources were typed in two places, dropping one made the module and the check
  disagree and the check went red. With one file and three readers a dropped source shrinks
  **both** sides equally — measured green on exactly that edit — so `launchd-log-rotation`
  gained a seventh leg asserting the **roster** (the four source `name`s). Names only: the
  `units`/`key`/`domain` mapping is deliberately **not** restated, because that mapping is the
  part that drifts silently, whereas a name roster is either right or red. Adding a fifth
  source is a deliberate act and must update that list.
  **Why truncation and not `pidFile` + `signal`:** the
  pinned nix-darwin module really does expose both (`newsyslog.nix:130-160`), so the option
  grep hits — but newsyslog only *delivers* a signal and the program must reopen its own path.
  `cloudflared --help` has **zero** sighup/reopen/rotate surface and `mcp-proxy` is a Python
  process with no handler, so the only effective signal is one that kills the process —
  rotation-by-restart, dropping the tunnel. Truncation needs no cooperation at all, because
  **launchd's inherited fd is O_APPEND**: measured 2026-09-22, `lsof +fg -p 61665` on the live
  `mcp-gateway` prints flags `R,W,AP` on fd **1u and 2u**, so every write seeks to EOF and a
  truncate to zero is reclaimed immediately by the same running process. `mcp-tunnel-connector`
  (pid 832) held its log the same way. **Both of those agents are gone (2026-10-02, with the MCP
  gateway) — the MEASUREMENT is not.** It was taken on them, it generalises to every launchd
  job this repo authors (that is the inherited-fd behaviour, not an `mcp-proxy` quirk), and the
  mechanism it chose still rotates `cloudflared` for nixpi's tunnel and every other long-lived
  agent. Re-measure on a current pid if you want it fresh; do not read the two dead names as a
  reason to revisit the choice. Cost, stated up front: `copytruncate`'s man page warns
  of "a very small time slice between copying the file and truncating it, so some logging data
  might be lost" — which is exactly why the re-exec set keeps mechanism 1 instead of folding
  into one tool. Custom surface disclosed: neither pinned input ships a logrotate module
  (grepped both, zero hits), so the config + the two ticks are this repo's — far smaller than
  forking home-manager's launcher (`modules/launchd/default.nix:140-143` emits exactly
  `#!<shell>` + `exec <args>`; there is no pid-file seam) for a signal that reclaims nothing.
  **Classification is derived, not hand-picked** (it used to be a typed list of attr names):
  `KeepAlive` absent → re-exec; `KeepAlive.SuccessfulExit == false` → re-exec; anything else →
  long-lived. The residual case is deliberately conservative — a re-exec job misfiled as
  long-lived still gets its bytes back, while the reverse silently reclaims nothing. And
  **paths win over agents**: a path claimed by any long-lived declaration leaves the newsyslog
  set, which is what resolves `/var/log/ollama-daemon.log` being written by BOTH the `KeepAlive`
  `ollama` daemon and the `StartInterval` `ollama-metal-guard` — the one log in the fleet no
  mechanism could reach before.
  **Paths are derived, not typed**, off the composed agents, because a hand-written list
  walks into two traps: `claude-desktop-mcp-sync` declares `StandardErrorPath` and **no**
  `StandardOutPath` (enumerate one key and the file is silently missed), and `media-queue` +
  `media-queue-power` declare the **same** path — 4 declarations, one file — so a per-agent
  list double-covers it. Reading both keys and `lib.unique`-ing makes both structural.
  Gates: `sudo newsyslog -nv -f <rendered>` parses every entry and resolves every path;
  `logrotate -d --state <tmp> <rendered>` dry-runs the copytruncate half. Neither is a flake
  check — run them by hand after changing the set.
- **`nix-homebrew.nix`** — Homebrew-itself install via `nix-homebrew`.
- **`xcode-license.nix`** (macos only) — runs *before* `brew bundle` to `mas install` Xcode
  when declared in `masApps` and `xcodebuild -license accept`, so formulae are not blocked by
  an unaccepted SDK license (Brewfile order is brews→casks→mas).
- **`github-runner.nix`** — `local.macosGithubRunner`: N hand-rolled launchd daemons running
  **ephemeral, org-level self-hosted GitHub Actions runners**. Built then retired 2026-07-16
  once nix-config's own CI no longer needed one; **revived 2026-08-23 for a different consumer**
  — `dontsell-ai`'s repos, whose macOS + Playwright + Prisma jobs neither GitHub-hosted (no
  hosted-minutes budget on that org) nor the native Linux builder (build-only, ephemeral,
  1 CPU / 8 GiB by default) can serve. `hosts/macos.nix` enables it with `count = 2`.
  - **Hand-rolled on purpose:** nix-darwin's `services.github-runners` hard-asserts
    `nix.enable = true` (it takes the runner's `nix` from `config.nix.package`), which is
    mutually exclusive with Determinate Nix (`nix.enable = false`). This module reproduces
    upstream's launchd setup and substitutes `pkgs.nix` — nothing else differs.
  - **Auth:** a GitHub **App** RS256 private key (the host-decrypted
    `gh-app-dontsell-ai-key.age`), used to mint a fresh ~1 h installation token per
    registration rather than holding a long-lived bearer credential. Scoped to *only*
    "Organization permissions → Self-hosted runners: Read and write".
  - **Security:** `--ephemeral` (one job per registration; launchd restart + re-register makes
    it self-healing), outbound-only. Only trusted push jobs may target `runs-on: [self-hosted,
    …]` — **never fork-PR workflows**, since the daemon inherits the operator's login
    environment. `arg0` is nix-darwin's `/bin/sh -c 'wait4path /nix/store && exec …'` wrapper —
    the launchd-naming rule's **boot-ordering exception** for daemons; the exec'd process is
    still `nix-github-runner-<instance>`.
  - **Labels:** `extraLabels` (default `[ "nix" ]`) is passed as `--labels` **without**
    `--no-default-labels`, so the effective set is `{self-hosted, macOS, ARM64} ∪ extraLabels`
    — GitHub assigns the first three server-side. `nix` is the **positive** toolchain
    discriminator against the Tart-VM lane (`local.tart.githubRunners.*`, which carries `tart` and
    runs in a stock Cirrus guest with no nix/cachix/postgres). Both lanes register into
    `dontsell-ai`'s single `Default` group, so without `nix` the only thing telling this lane
    apart is the *absence* of `tart`, and GitHub has no negative selector. **Widening a label
    set is free; narrowing is not** — `runs-on:` is a hard AND-match, so always: widen → verify
    live on an ONLINE runner for that scope → flip consumers one repo at a time → narrow last.
  - Also pins `postgresql`+pgvector onto the runners' PATH (`modules/home/default.nix`, `hiPrio`
    to resolve the duplicate `bin/psql`).

- **`ollama-daemon.nix`** — `local.ollamaDaemon`: ONE machine-wide `ollama serve`, so
  every account shares one process and one model store. It exists because a second account
  cannot share home-manager's `services.ollama`: that emits `launchd.agents.ollama`, which
  lives inside ONE login session and keeps its models in that user's home, forcing a choice
  between a duplicate 31 GB store and a server that vanishes when the operator logs out.
  Models live in `/var/lib/ollama/models` (the same `/var/lib` convention `github-runner.nix`
  uses); relocating the existing 31 GB was a RENAME, since /Users and /private/var are
  firmlinked onto the same APFS data volume.

  **upstream-first:** grepped the pinned nix-darwin — `modules/services/` has no `ollama.nix`
  and the string appears nowhere under `modules/`. Nothing models this, so the daemon is
  custom, but built on nix-darwin's own `launchd.daemons` primitive.

  Two details are load-bearing. It uses `command`, not `ProgramArguments`, because the
  boot-ordering exception in [`launchd-naming`](../../.claude/rules/launchd-naming.md) applies:
  a `RunAtLoad` daemon whose arg0 is a store path loses the race against determinate-nixd
  mounting `/nix`, exits 78, and never self-heals. And `environmentVariables` carries the
  POWER BUDGET (`OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=10m`).
  Those moved here from `services.ollama.environmentVariables` in `modules/home/default.nix` —
  they had to, because that option only ever reaches home-manager's own agent, so the block
  went inert the moment the capsule stopped managing the server. The local-rag capsule gained
  `local.rag.ollama.manageServer` (set false) so it does not stand up a competitor on 11434.

- **`metube.nix`** / **`yt-dlp-web-ui.nix`** — `local.meTube` and `local.ytDlpWebUi`, the two
  local download web UIs, each ONE launchd **user agent** bound to **127.0.0.1** and each
  built from source in `packages/` (neither is in nixpkgs). Both are on in `hosts/macos.nix`.
  Shared shape, and the reasons they diverge from the obvious defaults:
  - **Loopback is the whole auth story.** MeTube ships no login at all — upstream's
    SECURITY.md says that is deliberate and that a login means a reverse proxy — so binding
    the open API to the loopback address is what keeps it to this Mac.
    `CORS_ALLOWED_ORIGINS=*` is required by the Chrome extension, whose requests come from a
    `chrome-extension://<id>` origin that cannot be named; `*` sends no credentials and there
    is no login cookie to send.
  - **Downloads land in the user's own home, never in the state dir.** MeTube's `main.py`
    `state_dir_guard` 404s any file whose real path is under `STATE_DIR`, so an early layout
    that put the mp3s inside it made the download button serve a `text/plain` error that the
    browser saved as a `.txt`. Video/audio therefore go to the standard home folders and
    state (including `cookies.txt`) stays under `~/.local`.
  - **`deno` is not optional.** launchd inherits no Homebrew, and yt-dlp's YouTube extraction
    fails with no JS runtime — so `yt-dlp`, `ffmpeg`, `deno` and `aria2` are put on each
    agent's PATH explicitly.
- **`claude-managed-settings.nix`** (macos only, `local.claudeManagedSettings`) — the fleet's
  strongest agent-policy tier: a **root-owned** `/Library/Application Support/ClaudeCode/
  managed-settings.json`, written by `system.activationScripts.postActivation` with `install`
  (so content, mode 0644 and root:wheel are re-asserted every activation, not hoped for) —
  **marker FIRST, policy second**, because activation runs under `set -e`: policy-first meant a
  marker that failed to land stranded a root-owned policy file the kill switch could then never
  delete, while the inverted order's worst partial state is a marker with no policy, which
  `enable = false` cleans up. It also defines `system.activationScripts.checks.text`
  (`mkAfter`) — an **ownership precondition that ABORTS activation with exit 2** if
  `managed-settings.json` exists WITHOUT the `.nix-config-owned` marker beside it, naming both
  paths and telling the operator to rename the foreign file `.before-nix-darwin` (or set
  `enable = false`). It sits in `checks`, not `postActivation`, because `checks` is spliced
  BEFORE /etc, launchd, defaults and Homebrew, so activation can still back out cleanly.
  **What managed scope buys**, claimed only as far as the shipped binary (claude-code 2.1.260)
  evidences it, and split because the two halves lean on different properties: the deny list
  needs UNION, not override — "--disallowedTools and other deny and ask rules from the command
  line or the current session still apply", plus "Cannot delete permission rules from read-only
  settings" for the no-retraction half; `attribution` is value-resolved and needs the LADDER,
  where the strongest honest claim is that every per-key precedence sentence naming the sources
  puts managed first (`processWrapper`: "Honored from managed settings, a --settings/SDK-supplied
  settings file, and user settings, in that precedence order"; `modelPicker`: "the
  highest-precedence of those that defines modelPicker wins outright") and none states the
  reverse. NOT evidence for either, though this page cited it as such: `server-managed > MDM >
  managed-settings.json` describes how managed SOURCES compose AMONG THEMSELVES (first-wins vs
  merge) — a no-op here, since this fleet has exactly one managed source. So the floor still
  holds in a session where `~/.claude` was never materialised or was hand-edited,
  and under `bypassPermissions`, which this fleet's VS Code extension and `claude` terminal
  profile both start in.
  - **Content = the SECRET-VALUE denies + the three `attribution` keys**, restated verbatim
    from `modules/home/claude-guardrails.nix`. The duplication is the point, not drift:
    `permissions.deny` lists from every scope COMBINE (duplicates dropped), and each scope
    reaches where the other cannot — user scope reaches the devcontainer and any clone on a
    machine this Home Manager config never touched, managed scope reaches a session whose
    `~/.claude` was never written. Deriving one from the other by string-matching was rejected
    for the same reason `claude-guardrails.nix` records twice in its BODY (the `mcpfinder` note
    and the `attribution` note — not its header): a reworded upstream rule would yield a
    well-formed and completely EMPTY floor. The reverse pointer lives where an editor actually
    lands, immediately above the secret-value deny group in that file: *EDIT THIS GROUP, EDIT
    IT TWICE.*
  - **Scope rule for a new entry, one notch stricter than the user floor:** it must already be
    in `claude-guardrails.nix` AND be pure "never print a secret value" / "never sign work as
    an AI". Nothing that merely narrows a workflow, because there is no in-session override
    here — undoing a wrong entry is a rebuild, not a `/permissions` click. That is why the
    imperative-MCP and irreversible-remote groups (`gh pr merge`, force-push) stay at user
    scope.
  - **Path spellings are load-bearing:** only `//` and `~/`. A single leading `/` anchors at
    the settings SOURCE, and what that resolves to for the managed tier is undocumented — a
    `Read(/run/agenix/**)` spelled that way would match nothing, silently. The four `Read`
    rules port verbatim from the user-scope file because they already carry the safe spelling.
  - **The kill switch is real:** `enable = false` DELETES the file rather than merely stopping
    the rewrite, guarded by a `.nix-config-owned` marker beside it so it can never remove an
    MDM payload this fleet did not place. The marker claims the PATH in both directions —
    while it is present, `enable = false` may delete that file; while it is absent, activation
    REFUSES to write one. Refuse, not adopt: adopting would let a rebuild claim ownership of a
    file we never wrote, which `enable = false` would then delete.
  - **upstream-first:** no nix-darwin option writes an arbitrary `/Library` file —
    `environment.etc` is hard-coded to `/etc` (`modules/system/etc.nix`), and
    `environment.launchAgents`/`launchDaemons` to `/Library/Launch*`
    (`modules/system/launchd.nix`); `system.patches` only reverses a diff over files that
    already exist, and `system.defaults.CustomSystemPreferences` writes a preferences DOMAIN,
    not a JSON file at a path. Home Manager's `programs.claude-code` writes under `$HOME` as
    the user. Anthropic's own channel is an MDM configuration profile; this fleet has no MDM.
  - **No `managed-mcp.json` here, deliberately** — deploying that file suppresses the
    claude.ai connectors Claude Code fetches for itself unless `allowAllClaudeAiMcps` is set
    alongside, and this fleet runs four Gmail connectors plus Drive, Calendar and Slack. **That
    reason survived the gateway's death and the other one did not.** This bullet used to add that
    "for every server with no plugin owner, MCP's source of truth stays `modules/shared/mcp.nix`";
    since 2026-10-02 there is no such file and no such server — **every** MCP server lives in a
    plugin's `.mcp.json`, which no managed file and no check here can see. ADR-003 §5's blanket
    "MCP servers stay Nix-owned" was scoped on 2026-09-30 (its §10.6) and is now **fully
    retracted** (§ MCP after the gateway). So the case against `managed-mcp.json` is now purely
    the connector-suppression one — which is sufficient on its own.
  - **Coverage limit + how to verify:** managed settings do NOT reach an Anthropic-hosted
    cloud session (only server-managed ones do), which is a further reason the user- and
    project-scope layers stay put. `nix flake check` cannot see any of this — `/status` inside
    Claude Code must list `Enterprise managed settings (file)` under `Setting sources`; that is
    a step in [`new-mac-runbook.md`](../new-mac-runbook.md) § Manual steps Nix can't do. Because
    `pkgs.formats.json` already guarantees the bytes parse, what `/status` confirms is
    PLACEMENT; an unrecognised key stays accepted, listed and enforcing nothing.

