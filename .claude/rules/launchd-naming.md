# Launchd Naming — `nix-<kebab>` arg0, NEVER a bare interpreter

Every launchd unit **this repo authors** MUST expose a first argument whose **basename is
`nix-<activity-in-kebab-case>`** — e.g. `nix-mcp-gateway`, `nix-ollama-local`,
`nix-file-rotation-downloads`. The `arg0` the kernel execs (`ProgramArguments[0]`, or
`Program` if used) is what macOS's **Background Task Manager (BTM)** and *System Settings →
Login Items & Extensions* display. A bare interpreter there — `sh`, `bash`, `zsh`, `dash`,
`python`/`python3`, `node`, `perl`, `ruby`, `env` — is **forbidden**: it hides the
nix-config origin, is indistinguishable from third-party or malicious persistence, and is
the exact smell this rule exists to prevent.

## Why

BTM lists background agents by their executable basename. A `nix-*` basename **tags every
fleet agent as ours**, so the operator can audit "Allow in the Background" at a glance and
spot anything that is *not* ours. `sh`/`python3` defeats that entirely.

### The rule is load-bearing for TCC file access, not just BTM cosmetics

A `/nix/store` `arg0` is also what lets an agent **read** the TCC-protected user folders
(Desktop / Documents / **Downloads**). Measured on this machine:

| Agent `arg0` | Reading / enumerating `~/Downloads` |
|---|---|
| `/nix/store/…/bin/nix-<activity>` (what `writeShellScriptBin` produces — adhoc-signed) | **ALLOWED** |
| `/bin/sh` (i.e. `script =`, or an explicit `/bin/sh -c`) — identical job otherwise | **EPERM** |

TCC gates *reads* of those folders and attributes the access to the **responsible process**.
An adhoc-signed `/nix/store` binary has no stable code identity to attribute, so it falls
through to allow; Apple's own `/bin/sh` is attributable and gets denied without an explicit
grant. Consequence: **`script =` or a bare-interpreter `arg0` now silently loses Downloads
access** — the agent runs, logs nothing useful, and quietly does no work.

**Caveat:** this behaviour is **undocumented by Apple** and **verified on macOS 26.6.2 only**.
It could change in any OS update. Treat it as one more reason the `nix-*` wrapper is
mandatory, not as a security boundary to rely on. Live example:
`nix-file-rotation-downloads` in `modules/darwin/core.nix`.

## Mandatory behavior

1. **Home Manager user agents** (`launchd.user.agents.*`) are wrapped automatically by
   `modules/shared/hm-launchd/`, which forces `arg0` to `nix-<name>`. Do not bypass it.
   This is upstream's own `waitForNixStore = false` trade, in its words (pinned
   home-manager `modules/launchd/default.nix:47-52`): the agent "appear[s] under its own
   name, rather than as 'sh' … but the agent will fail to start if launchd runs it before
   the Nix store is mounted." **There is no wait4path inside the wrapper** — the wrapper
   is itself a `/nix/store` script with a `/nix/store` interpreter, so launchd needs the
   store mounted just to exec it. Cover an early-boot start with `KeepAlive` (which makes
   launchd retry the failed exec), not with a wait4path line that cannot run.
2. **Any launchd unit you hand-write** — a `launchd.user.agents` entry with an explicit
   `ProgramArguments`, or a nix-darwin `launchd.daemons`/`launchd.agents` you author — MUST
   point `arg0` at a `pkgs.writeShellScriptBin "nix-<activity>" ''…''` wrapper, **never**
   directly at `${pkgs.bash}/bin/sh -c …` or `${python}/bin/python3 …`. Put the `exec`
   logic inside that wrapper — and NOT a `wait4path`, for the reason in item 1: it is
   unreachable from a store-resident wrapper. Canonical examples in
   `modules/shared/mcp.nix`: `telegramMcp` (`nix-telegram-mcp`), `wpMcp`
   (`nix-mcp-wordpress`), `apifyMcp` (`nix-mcp-apify`).
3. **Before declaring any launchd change done**, mentally (or with the audit below) confirm
   the new unit's `arg0` basename starts with `nix-`.

## The boot-ordering exception — ours, and deliberate

**A unit whose executable lives in `/nix` and must start at BOOT cannot follow the
`arg0` rule.** `/nix` is a separate `noauto` APFS volume mounted by
`determinate-nixd`; at boot launchd tries to exec a path that does not exist yet.
Measured on this machine, 2026-09-06:

```
12:33:27.417  launchd: "Missing executable detected" x2  -> exit 78 EX_CONFIG
12:33:28.393  determinate_nixd: "Unlocking and mounting /nix"   <- 976 ms TOO LATE
```

It then **never self-heals**: launchd parks the job on an "Executable appearance"
retry event that does **not** fire when the file arrives via a *volume mount*.
`services.macosGithubRunner`'s two daemons sat at `runs = 1,
state = spawn scheduled` for an entire 10h52m uptime, and `darwin-rebuild switch`
did not recover them (nix-darwin only re-bootstraps daemons whose plist changed).

**No launchd setting fixes this.** Measured with a throwaway agent pointing at a
missing executable, then creating it:

| Setting | Retried the failed exec? |
|---|---|
| `StartInterval = 10` | **No** — `runs` stayed 1 |
| `KeepAlive = true` | **No** — `runs` stayed 1 |
| `KeepAlive.PathState` | **No** — dict keys are OR'd (defeats `Crashed = false`), and it does not fire on volume mounts either |

So the executable must exist when launchd *first* tries, which means `arg0` has to
be a path **outside** `/nix`. Use nix-darwin's own
`launchd.daemons.<name>.command` (`modules/launchd/default.nix:90-94`), which
emits `/bin/sh -c '/bin/wait4path /nix/store && exec <command>'` — the same shape
`activate-system` and `activate-agenix` use, for the same reason.

**Scope this narrowly.** It applies ONLY to a `launchd.daemons` unit that must run
at boot from a store path. It does NOT apply to `launchd.user.agents` (they start
after login, long after `/nix` is mounted) — those keep the `nix-*` wrapper, and
`modules/shared/hm-launchd/` still enforces it.

**Why the cost is acceptable here:** this rule's load-bearing half is TCC — an
adhoc-signed `/nix/store` `arg0` keeps read access to `~/Desktop`, `~/Documents`
and `~/Downloads`. The runner daemons run as `_github-runner` and touch only
`/var/lib`; they read none of those. Only BTM legibility is lost, and the process
after `exec` is still `nix-github-runner-<instance>`.

Live example: `services.macosGithubRunner` in `modules/darwin/github-runner.nix`.

### A CRASH is retried; a failed EXEC is not — that asymmetry is the whole bug

The table above says no launchd setting recovers a **failed exec**. It does not say
launchd never retries — it retries a **crash** just fine. That is why the boot has two
races and only one of them was fatal. Measured on the 2026-09-06 reboot that verified
this fix:

| Race | What launchd sees | Recovers? |
|---|---|---|
| daemon execs before `/nix` is mounted | **failed exec** (`Missing executable`, exit 78 EX_CONFIG) | **NO** — parks forever on an "Executable appearance" event that a volume mount does not fire |
| daemon runs before `activate-agenix` writes `/run/agenix/<key>` | **crash** (runner exits 1, `Could not open file ... No such file or directory`) | **YES** — `KeepAlive` restarts it |

Boot timeline, same reboot: boot `10:21:52` → daemons exec cleanly (`/nix` mounted in
time — `wait4path` did its job) → **exit 1**, secret absent → `10:22:40`
`activate-agenix` decrypts → launchd retries → `10:24:11` both runners
`Listening for Jobs`.

**So the agenix race is left unfixed on purpose.** It costs ~2 min of runner
unavailability at boot, when nothing is queued, and it self-heals. Do not "fix" it by
adding a second wait-for-file guard to the daemon command — a `runs = 2,
last exit code = 1` on these daemons is expected after a reboot and is **not** the boot
race. The one to alarm on is `runs = 1, last exit code = 78`.

## Known upstream exceptions — do NOT rename (they are not ours)

Three system `LaunchDaemons` run `/bin/sh` and are **outside this repo's control**. They are
**expected** and must be left alone:

- **`org.nixos.activate-system`** — nix-darwin core's boot-time activation daemon
  (`/bin/sh -c 'wait4path /nix/store && exec …activate-system-start'`). Emitted by
  nix-darwin itself; renaming it fights nix-darwin internals and can break `darwin-rebuild`
  activation.
- **`org.nixos.activate-agenix`** — the `agenix` flake input's own activation daemon (same
  `/bin/sh -c 'wait4path ... && exec ...'` shape as `activate-system`). Emitted entirely by
  agenix's nix-darwin module — grep this repo's `.nix` files for `activate-agenix` and you
  get zero hits. Same rationale as `activate-system`: not ours to rename.
- **`systems.determinate.nix-installer.nix-hook`** — the Determinate Nix installer's
  self-repair hook (`/bin/sh -c 'wait4path /nix/nix-installer && nix-installer repair'`).
  Placed by the `curl | bash` installer, **not** Nix-managed; any edit is imperative and is
  clobbered by the next Determinate update.

Seeing these three as `sh` in BTM is **not** a rule violation — the rule governs agents this
repo defines, and all of those must be `nix-*`. Do not "fix" these; do not report them as
violations.

## Quick audit

```bash
for p in "$HOME"/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist; do
  [ -e "$p" ] || continue
  a0=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$p" 2>/dev/null)
  [ -z "$a0" ] && a0=$(/usr/bin/plutil -extract Program raw -o - "$p" 2>/dev/null)
  case "$(basename "$a0")" in sh|bash|zsh|dash|python|python3|node|perl|ruby|env)
    echo "BARE-INTERP: $(/usr/bin/plutil -extract Label raw -o - "$p") -> $a0 ($p)";; esac
done
```

**Expected hits, in full** — this audit prints five `BARE-INTERP` lines on `macos` today and
every one of them is fine:

| Label | Why it is `/bin/sh` |
|---|---|
| `org.nixos.activate-system` | upstream nix-darwin (§ Known upstream exceptions) |
| `org.nixos.activate-agenix` | upstream agenix (§ Known upstream exceptions) |
| `systems.determinate.nix-installer.nix-hook` | the Determinate installer (§ Known upstream exceptions) |
| `org.nixos.github-runner-macos-*` | **ours, and deliberate** — the boot-ordering exception above |

Anything else whose `Label` is one of ours (`org.nixos.*` — every nix-darwin unit this repo
authors carries that prefix, including `org.nixos.open-*` and `org.nixos.file-rotation-*` —
or `org.nix-community.home.*`, or `com.kattakath.*`) is a real violation: fix it by wrapping
`arg0` in a `nix-<activity>` `writeShellScriptBin`.
