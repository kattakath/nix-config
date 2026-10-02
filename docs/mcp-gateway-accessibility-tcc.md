# macOS Accessibility (TCC) for `macos-automator`

> **The filename is the only stale thing here — the grant and its reasoning are STILL CORRECT.**
> The MCP gateway (`modules/shared/mcp.nix`) was deleted 2026-10-02, and `macos-automator` had
> already moved to the **`mac-app-send` plugin** on 2026-10-01, where Claude Code spawns it per
> session. **The grant carried over unchanged**, and this document explains exactly why it had to:
> TCC attributes the grant to `/usr/bin/osascript`, **not** to whatever parent spawned it. That was
> the whole argument of § *Why granting `/usr/bin/osascript` is the correct, rebuild-proof fix* —
> written against a store path that rehashes every rebuild, and it generalises to a parent that
> changes identity entirely. Substitute "the plugin's per-session child" for "the gateway" as you
> read.

`macos-automator` drives **System Events UI scripting** through `/usr/bin/osascript`.
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

After granting, run the probe directly (it is the same one the gateway's preflight used):

```bash
osascript -e 'tell application "System Events" to get name of first process'
```

- **Granted:** prints a process name (e.g. `WindowServer`) and exits `0`.
- **Not granted:** prints `… osascript is not allowed assistive access. (-1719)`.

**The activation preflight is GONE (2026-10-02).** `darwin-rebuild switch` used to run this probe
as a **non-fatal preflight** and print the grant instructions if — and only if — the grant was
missing (`home.activation.macosAutomatorAccessibilityCheck` in `modules/shared/mcp.nix`). It never
blocked activation, and it went with that module. **So nothing warns you any more**: a missing grant
now surfaces as a `-1719` error inside a session, which is the failure this preflight existed to
pre-empt. Run the probe by hand after a fresh Mac setup — it is a step in
[`new-mac-runbook.md`](new-mac-runbook.md) territory, not something any check can cover.

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

- The **`mac-app-send` plugin** in `github:kattakath/skills` — owns the `macos-automator` server
  entry since 2026-10-01. ~~`modules/shared/mcp.nix`~~ held it, plus the non-fatal activation
  preflight, until both were deleted 2026-10-02.
- The first time `macos-automator` controls *another* app (not System Events),
  macOS also shows a one-time **Automation** consent prompt — that one *is*
  promptable and needs no manual step.
