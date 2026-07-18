# MCP gateway — macOS Accessibility (TCC) for `macos-automator`

The localhost MCP gateway (`modules/shared/mcp.nix`) hosts a `macos-automator`
server that drives **System Events UI scripting** through `/usr/bin/osascript`.
UI scripting is gated by macOS **Accessibility** (TCC service
`kTCCServiceAccessibility`). Without the grant, every UI-scripting call fails
with:

```
execution error: System Events got an error: osascript is not allowed assistive access. (-1719)
```

This is a **one-time manual grant** — it cannot be made declarative (TCC.db is
SIP-protected; there is no supported API to add an Accessibility entry, and
`tccutil` can only *reset*, never *grant*). Once added it is **stable across
`darwin-rebuild switch`**, for the reason spelled out under
[Why granting `/usr/bin/osascript` is the correct, rebuild-proof fix](#why-granting-usrbinosascript-is-the-correct-rebuild-proof-fix).

## The fix — grant `/usr/bin/osascript` Accessibility (once)

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Click **`+`**.
3. In the file picker press **⇧⌘G** (Go to Folder) and type:

   ```
   /usr/bin/osascript
   ```

4. Press **Enter**, click **Open**, and make sure the new `osascript` row's
   toggle is **on**.

`osascript` is a hidden system binary, so it will not appear by browsing — the
**⇧⌘G → `/usr/bin/osascript`** path entry is the only way to add it.

### Verify

After granting, run the exact probe the gateway uses:

```bash
osascript -e 'tell application "System Events" to get name of first process'
```

- **Granted:** prints a process name (e.g. `WindowServer`) and exits `0`.
- **Not granted:** prints `… osascript is not allowed assistive access. (-1719)`.

`darwin-rebuild switch` also runs this probe as a **non-fatal preflight** and
prints the grant instructions (and a pointer to this doc) if — and only if — the
grant is missing (see `home.activation.macosAutomatorAccessibilityCheck` in
`modules/shared/mcp.nix`). It never blocks activation.

## Why granting `/usr/bin/osascript` is the correct, rebuild-proof fix

The concern with the gateway is that TCC attribution might fall on a **Nix store
path that rehashes every rebuild**, silently breaking any grant on the next
switch. It does not, because of how the process chain actually resolves:

```
launchd  →  /bin/sh -c 'wait4path /nix/store && exec <store>/mcp-proxy …'
              └─ exec REPLACES the image →  <store>/…/mcp-proxy  (python)
                   └─ npx  →  node (macos-automator-mcp)
                        └─ /usr/bin/osascript          ← the process making the AX call
```

Two facts settle it:

1. **The AX caller is `/usr/bin/osascript`** — a stable, Apple-signed system
   path. The gateway launchd agent's `PATH` ends in `…:/usr/bin:/bin` and
   nothing earlier on it provides `osascript`, so the system binary is always
   the one that runs. Its identity never changes across rebuilds, so a grant
   against it never breaks. The error message even names it directly.

2. **No stable-path wrapper can do better.** Home Manager renders *every*
   `launchd.agents.<name>` as
   `/bin/sh -c '/bin/wait4path /nix/store && exec <store>/…'`
   (confirmed via `launchctl print gui/$UID/org.nix-community.home.mcp-gateway`
   → `program = /bin/sh`, `inferred program`). So:
   - launchd's *tracked* program is the generic **`/bin/sh`** — granting *that*
     Accessibility would (a) hand AX to every `/bin/sh` script on the box and
     (b) is the classic unreliable "interpreter-attribution" case; not a real
     fix.
   - the `exec` then **replaces** the shell image with the store-path
     `mcp-proxy`, so the live process is a store path that rehashes each
     rebuild.
   - inserting our own stable-path launcher (e.g. `~/.local/bin/mcp-gateway`,
     or an `/etc/profiles/per-user/…` entry) just becomes one more `exec`
     target in that chain — it still terminates at the store binary, and the
     launchd-tracked program stays `/bin/sh`. **TCC also resolves symlinks**, so
     a profile symlink into `/nix/store` is recorded as the store path anyway.

   There is therefore no wrapper that yields a *stable* responsible-process
   identity here, which is exactly why the gateway's launchd `ProgramArguments`
   are left untouched and the fix lives entirely in the `/usr/bin/osascript`
   grant.

## Related

- `modules/shared/mcp.nix` — the gateway, the `macos-automator` server entry,
  and the non-fatal activation preflight.
- The first time `macos-automator` controls *another* app (not System Events),
  macOS also shows a one-time **Automation** consent prompt — that one *is*
  promptable and needs no manual step.
