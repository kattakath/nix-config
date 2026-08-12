# Launchd Naming — `nix-<kebab>` arg0, NEVER a bare interpreter

Every launchd unit **this repo authors** MUST expose a first argument whose **basename is
`nix-<activity-in-kebab-case>`** — e.g. `nix-mcp-gateway`, `nix-ollama-local`,
`nix-file-rotation-screengrab`. The `arg0` the kernel execs (`ProgramArguments[0]`, or
`Program` if used) is what macOS's **Background Task Manager (BTM)** and *System Settings →
Login Items & Extensions* display. A bare interpreter there — `sh`, `bash`, `zsh`, `dash`,
`python`/`python3`, `node`, `perl`, `ruby`, `env` — is **forbidden**: it hides the
nix-config origin, is indistinguishable from third-party or malicious persistence, and is
the exact smell this rule exists to prevent.

## Why

BTM lists background agents by their executable basename. A `nix-*` basename **tags every
fleet agent as ours**, so the operator can audit "Allow in the Background" at a glance and
spot anything that is *not* ours. `sh`/`python3` defeats that entirely.

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

Two system `LaunchDaemons` run `/bin/sh` and are **outside this repo's control**. They are
**expected** and must be left alone:

- **`org.nixos.activate-system`** — nix-darwin core's boot-time activation daemon
  (`/bin/sh -c 'wait4path /nix/store && exec …activate-system-start'`). Emitted by
  nix-darwin itself; renaming it fights nix-darwin internals and can break `darwin-rebuild`
  activation.
- **`systems.determinate.nix-installer.nix-hook`** — the Determinate Nix installer's
  self-repair hook (`/bin/sh -c 'wait4path /nix/nix-installer && nix-installer repair'`).
  Placed by the `curl | bash` installer, **not** Nix-managed; any edit is imperative and is
  clobbered by the next Determinate update.

Seeing these two as `sh` in BTM is **not** a rule violation — the rule governs agents this
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
