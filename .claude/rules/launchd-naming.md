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
   `modules/shared/hm-launchd/`, which forces `arg0` to `nix-<name>` and keeps `wait4path`
   **inside** the wrapper. Do not bypass it.
2. **Any launchd unit you hand-write** — a `launchd.user.agents` entry with an explicit
   `ProgramArguments`, or a nix-darwin `launchd.daemons`/`launchd.agents` you author — MUST
   point `arg0` at a `pkgs.writeShellScriptBin "nix-<activity>" ''…''` wrapper, **never**
   directly at `${pkgs.bash}/bin/sh -c …` or `${python}/bin/python3 …`. Put the
   `wait4path`/`exec` logic inside that wrapper. Canonical examples in
   `modules/shared/mcp.nix`: `telegramMcp` (`nix-telegram-mcp`), `wpMcp`
   (`nix-mcp-wordpress`), `cloudflaredConnector` (`nix-mcp-tunnel-connector`).
3. **Before declaring any launchd change done**, mentally (or with the audit below) confirm
   the new unit's `arg0` basename starts with `nix-`.

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

Any hit that is **not** one of the two known upstream exceptions above, and whose `Label`
is one of ours (`org.nix-community.home.*`, `org.nixos.open-*`, `com.kattakath.*`), is a
real violation — fix it by wrapping `arg0` in a `nix-<activity>` `writeShellScriptBin`.
